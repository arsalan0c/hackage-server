{-# LANGUAGE DoRec, RankNTypes, NamedFieldPuns, RecordWildCards #-}
module Distribution.Server.Features.Html (
    HtmlFeature(..),
    initHtmlFeature
  ) where

import Distribution.Server.Framework
import qualified Distribution.Server.Framework.ResponseContentTypes as Resource

import Distribution.Server.Features.Core
import Distribution.Server.Features.RecentPackages
import Distribution.Server.Features.Upload
import Distribution.Server.Features.PackageCandidates
import Distribution.Server.Features.Users
import Distribution.Server.Features.DownloadCount
import Distribution.Server.Features.NameSearch
import Distribution.Server.Features.PreferredVersions
-- [reverse index disabled] import Distribution.Server.Features.ReverseDependencies
import Distribution.Server.Features.PackageList
import Distribution.Server.Features.Tags
import Distribution.Server.Features.Mirror
import Distribution.Server.Features.Distro
import Distribution.Server.Features.Documentation

import Distribution.Server.Users.Types
import qualified Distribution.Server.Users.Group as Group
import Distribution.Server.Packages.Types
import Distribution.Server.Packages.Render
import qualified Distribution.Server.Users.Users as Users
import qualified Distribution.Server.Packages.PackageIndex as PackageIndex
import Distribution.Server.Users.Group (UserGroup(..))
import Distribution.Server.Features.Distro.Distributions (DistroPackageInfo(..))
-- [reverse index disabled] import Distribution.Server.Packages.Reverse

import qualified Distribution.Server.Pages.Package as Pages
import Distribution.Server.Pages.Template (hackagePage, hackagePageWith, haddockPage)
import Distribution.Server.Pages.Util
import qualified Distribution.Server.Pages.Group as Pages
-- [reverse index disabled] import qualified Distribution.Server.Pages.Reverse as Pages
import qualified Distribution.Server.Pages.Index as Pages

import Distribution.Package
import Distribution.Version
import Distribution.Text (display)
import Distribution.PackageDescription

import Data.List (intercalate, intersperse, insert, sortBy)
import Data.Function (on)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe (fromMaybe)
import System.FilePath.Posix ((</>))

import Text.XHtml.Strict
import qualified Text.XHtml.Strict as XHtml
import Text.XHtml.Table (simpleTable)


-- TODO: move more of the below to Distribution.Server.Pages.*, it's getting
-- close to 1K lines, way too much... it's okay to keep data-querying in here,
-- but pure HTML generation mostly needlessly clutters up the module.
-- Try to make it so no HTML combinators need to be imported.
--
-- See the TODO file for more ways to improve the HTML.
data HtmlFeature = HtmlFeature {
    htmlFeatureInterface :: HackageFeature
}

instance IsHackageFeature HtmlFeature where
    getFeatureInterface = htmlFeatureInterface

-- This feature provides the HTML view to the models of other features
-- currently it uses the xhtml package to render HTML (Text.XHtml.Strict)
--
-- This means of generating HTML is somewhat temporary, in that a more advanced
-- (and better-looking) HTML ajaxy scheme should come about later on.
initHtmlFeature :: ServerEnv -> UserFeature -> CoreFeature -> RecentPackagesFeature
                -> UploadFeature -> PackageCandidatesFeature -> VersionsFeature
                -- [reverse index disabled] -> ReverseFeature
                -> TagsFeature -> DownloadFeature
                -> ListFeature -> NamesFeature
                -> MirrorFeature -> DistroFeature
                -> DocumentationFeature
                -> IO HtmlFeature

initHtmlFeature ServerEnv{serverCacheDelay, serverVerbosity = verbosity}
                user core@CoreFeature{packageIndexChange}
                packages upload
                candidates versions
                -- [reverse index disabled] reverse
                tags download
                list@ListFeature{itemUpdate}
                names mirror
                distros docs = do

    loginfo verbosity "Initialising html feature, start"

    -- do rec, tie the knot
    rec let (feature, packageIndex, packagesPage) =
              htmlFeature user core
                          packages upload
                          candidates versions
                          tags download
                          list names
                          mirror distros docs
                          (htmlUtilities core tags)
                          mainCache namesCache

        -- Index page caches
        mainCache  <- newAsyncCacheNF packageIndex
                        defaultAsyncCachePolicy {
                          asyncCacheName = "packages index page (by category)",
                          asyncCacheUpdateDelay  = serverCacheDelay,
                          asyncCacheSyncInit     = False,
                          asyncCacheLogVerbosity = verbosity
                        }

        namesCache <- newAsyncCacheNF packagesPage
                        defaultAsyncCachePolicy {
                          asyncCacheName = "packages index page (by name)",
                          asyncCacheUpdateDelay  = serverCacheDelay,
                          asyncCacheLogVerbosity = verbosity
                        }

    registerHook itemUpdate $ \_ ->   prodAsyncCache mainCache
                                   >> prodAsyncCache namesCache
    registerHook packageIndexChange $ prodAsyncCache mainCache
                                   >> prodAsyncCache namesCache

    loginfo verbosity "Initialising html feature, end"
    return feature

htmlFeature :: UserFeature
            -> CoreFeature
            -> RecentPackagesFeature
            -> UploadFeature
            -> PackageCandidatesFeature
            -> VersionsFeature
            -> TagsFeature
            -> DownloadFeature
            -> ListFeature
            -> NamesFeature
            -> MirrorFeature
            -> DistroFeature
            -> DocumentationFeature
            -> HtmlUtilities
            -> AsyncCache Response
            -> AsyncCache Response
            -> (HtmlFeature, IO Response, IO Response)

htmlFeature user
            core@CoreFeature{queryGetPackageIndex}
            recent upload
            candidates versions
            -- [reverse index disabled] ReverseFeature{..}
            tags download
            list@ListFeature{getAllLists}
            names
            mirror distros
            docs
            utilities@HtmlUtilities{..}
            cachePackagesPage cacheNamesPage
  = (HtmlFeature{..}, packageIndex, packagesPage)
  where
    htmlFeatureInterface = (emptyHackageFeature "html") {
        featureResources = htmlResources
      , featureState     = []
      , featureCaches    = [
           CacheComponent {
             cacheDesc       = "packages page by category",
             getCacheMemSize = memSize <$> readAsyncCache cachePackagesPage
           }
         , CacheComponent {
             cacheDesc       = "packages page by name",
             getCacheMemSize = memSize <$> readAsyncCache cacheNamesPage
           }
         ]
      , featurePostInit = syncAsyncCache cachePackagesPage
      }

    -- pages defined for the HTML feature in particular

    htmlCore       = mkHtmlCore core versions upload tags docs download distros recent htmlTags htmlPreferred utilities cachePackagesPage cacheNamesPage
    htmlUsers      = mkHtmlUsers user
    htmlUploads    = mkHtmlUploads upload utilities
    htmlCandidates = mkHtmlCandidates core upload versions candidates utilities
    htmlPreferred  = mkHtmlPreferred core versions utilities
    htmlDownloads  = mkHtmlDownloads download utilities
    htmlTags       = mkHtmlTags core tags list utilities
    htmlSearch     = mkHtmlSearch names list utilities

    htmlResources = concat [
        htmlCoreResources       htmlCore
      , htmlUsersResources      htmlUsers
      , htmlUploadsResources    htmlUploads
      , htmlCandidatesResources htmlCandidates
      , htmlPreferredResources  htmlPreferred
      , htmlDownloadsResources  htmlDownloads
      , htmlTagsResources       htmlTags
      , htmlSearchResources     htmlSearch
      -- and user groups. package maintainers, trustees, admins
      , htmlGroupResource user (packageGroupResource . uploadResource $ upload)
      , htmlGroupResource user (trusteeResource      . uploadResource $ upload)
      , htmlGroupResource user (uploaderResource     . uploadResource $ upload)
      , htmlGroupResource user (adminResource        . userResource   $ user)
      , htmlGroupResource user (mirrorGroupResource  . mirrorResource $ mirror)
      ]




      -- TODO: write HTML for reports and distros to display the information
      -- effectively reports
      {-
      , (extendResource $ reportsList reports) {
            resourceGet = [("html", serveReportsList)]
          }
      , (extendResource $ reportsPage reports) {
            resourceGet = [("html", serveReportsPage)]
          }
      -}

      -- distros
      {-
      , (extendResource $ distroIndexPage distros) {
            resourceGet = [("html", serveDistroIndex)]
          }
      , (extendResource $ distroAllPage distros) {
            resourceGet = [("html", serveDistroPackages)]
          }
      , (extendResource $ distroPackage distros) {
            resourceGet = [("html", serveDistroPackage)]
          }
      -}


      -- reverse index (disabled)
      {-
      , (extendResource $ reversePackage reverses) {
            resourceGet = [("html", serveReverse True)]
          }
      , (extendResource $ reversePackageOld reverses) {
            resourceGet = [("html", serveReverse False)]
          }
      , (extendResource $ reversePackageAll reverses) {
            resourceGet = [("html", serveReverseFlat)]
          }
      , (extendResource $ reversePackageStats reverses) {
            resourceGet = [("html", serveReverseStats)]
          }
      , (extendResource $ reversePackages reverses) {
            resourceGet = [("html", serveReverseList)]
          }
      -}



    -- [reverse index disabled] reverses = reverseResource






    {- [reverse index disabled]
    --------------------------------------------------------------------------------
    -- Reverse
    serveReverse :: Bool -> DynamicPath -> ServerPart Response
    serveReverse isRecent dpath =
      htmlResponse $
      withPackageId dpath $ \pkgid -> do
        let pkgname = packageName pkgid
        rdisp <- case packageVersion pkgid of
                  Version [] [] -> withPackageAll pkgname   $ \_ -> revPackageName pkgname
                  _             -> withPackageVersion pkgid $ \_ -> revPackageId pkgid
        render <- (if isRecent then renderReverseRecent else renderReverseOld) pkgname rdisp
        return $ toResponse $ Resource.XHtml $ hackagePage (display pkgname ++ " - Reverse dependencies ") $
            Pages.reversePackageRender pkgid (corePackageUri "") revr isRecent render

    serveReverseFlat :: DynamicPath -> ServerPart Response
    serveReverseFlat dpath = htmlResponse $
                                      withPackageAllPath dpath $ \pkgname _ -> do
        revCount <- query $ GetReverseCount pkgname
        pairs <- revPackageFlat pkgname
        return $ toResponse $ Resource.XHtml $ hackagePage (display pkgname ++ "Flattened reverse dependencies") $
            Pages.reverseFlatRender pkgname (corePackageName "") revr revCount pairs

    serveReverseStats :: DynamicPath -> ServerPart Response
    serveReverseStats dpath = htmlResponse $
                                       withPackageAllPath dpath $ \pkgname pkgs -> do
        revCount <- query $ GetReverseCount pkgname
        return $ toResponse $ Resource.XHtml $ hackagePage (display pkgname ++ "Reverse dependency statistics") $
            Pages.reverseStatsRender pkgname (map packageVersion pkgs) (corePackageUri "") revr revCount

    serveReverseList :: DynamicPath -> ServerPart Response
    serveReverseList _ = do
        let revr = reverseResource revs
        triple <- sortedRevSummary revs
        hackCount <- PackageIndex.indexSize <$> queryGetPackageIndex
        return $ toResponse $ Resource.XHtml $ hackagePage "Reverse dependencies" $
            Pages.reversePackagesRender (corePackageName "") revr hackCount triple
    -}

    --------------------------------------------------------------------------------
    -- Additional package indices

    packageIndex :: IO Response
    packageIndex = do
       index <- queryGetPackageIndex
       let htmlIndex = toResponse $ Resource.XHtml $ Pages.packageIndex index
       return htmlIndex

    packagesPage :: IO Response
    packagesPage = do
        items <- liftIO $ getAllLists
        let htmlpage =
              toResponse $ Resource.XHtml $ hackagePage "All packages by name" $
                [ h2 << "All packages by name"
                , ulist ! [theclass "packages"] << map renderItem (Map.elems items)
                ]
        return htmlpage


    {-
    -- Currently unused, mainly because not all web browsers use eager authentication-sending
    -- Setting a cookie might work here, albeit one that's stateless for the server, is not
    -- used for auth and only causes GUI changes, not permission overriding
    loginWidget :: UserResource -> ServerPart Html
    loginWidget user = do
        users <- query State.GetUserDb
        auth  <- Auth.getHackageAuth users
        return . makeLoginWidget user $ case auth of
            Left {} -> Nothing
            Right (_, uinfo) -> Just $ userName uinfo

    makeLoginWidget :: UserResource -> Maybe UserName -> Html
    makeLoginWidget user mname = case mname of
        Nothing -> anchor ! [href $ userLoginUri user Nothing] << "log in"
        Just uname -> anchor ! [href $ userPageUri user "" uname] << display uname
    -}


{-------------------------------------------------------------------------------
  Core
-------------------------------------------------------------------------------}

data HtmlCore = HtmlCore {
    htmlCoreResources :: [Resource]
  }

mkHtmlCore :: CoreFeature
           -> VersionsFeature
           -> UploadFeature
           -> TagsFeature
           -> DocumentationFeature
           -> DownloadFeature
           -> DistroFeature
           -> RecentPackagesFeature
           -> HtmlTags
           -> HtmlPreferred
           -> HtmlUtilities
           -> AsyncCache Response
           -> AsyncCache Response
           -> HtmlCore
mkHtmlCore CoreFeature{..}
           VersionsFeature{..}
           UploadFeature{..}
           TagsFeature{..}
           DocumentationFeature{..}
           DownloadFeature{..}
           DistroFeature{..}
           RecentPackagesFeature{..}
           HtmlTags{..}
           HtmlPreferred{..}
           HtmlUtilities{..}
           cachePackagesPage
           cacheNamesPage = HtmlCore{..}
  where
    cores = coreResource
    versions = versionsResource
    uploads = uploadResource

    maintainPackage   = (resourceAt "/package/:package/maintain") {
                            resourceGet = [("html", serveMaintainLinks editDeprecated editPreferred $ packageGroupResource uploads)]
                          }

    htmlCoreResources = [
        (extendResource $ corePackagePage cores) {
            resourceDesc = [(GET, "Show detailed package information")]
          , resourceGet  = [("html", servePackagePage)]
          }
      {-
      , (extendResource $ coreIndexPage cores) {
            resourceGet = [("html", serveIndexPage)]
          }, currently in 'core' feature
      -}
      , (resourceAt "/packages/names" ) {
            resourceGet = [("html", const $ readAsyncCache cacheNamesPage)]
          }
      , (extendResource $ corePackagesPage cores) {
            resourceDesc = [(GET, "Show package index")]
          , resourceGet  = [("html", const $ readAsyncCache cachePackagesPage)]
          }
      , maintainPackage
      ]

    -- Currently the main package page is thrown together by querying a bunch
    -- of features about their attributes for the given package. It'll need
    -- reorganizing to look aesthetic, as opposed to the sleek and simple current
    -- design that takes the 1990s school of web design.
    servePackagePage :: DynamicPath -> ServerPart Response
    servePackagePage dpath =
                            htmlResponse $
                            withPackageId dpath $ \pkgid  ->
                            withPackagePreferred pkgid $ \pkg pkgs -> do
        -- get the PackageRender from the PkgInfo
        render <- liftIO $ packageRender pkg
        let realpkg = rendPkgId render
            pkgname = packageName realpkg
            middleHtml = Pages.renderFields render
        -- get additional information from other features
        prefInfo <- queryGetPreferredInfo pkgname
        let infoUrl = fmap (\_ -> preferredPackageUri versions "" pkgname) $ sumRange prefInfo
            beforeHtml = [Pages.renderVersion realpkg (classifyVersions prefInfo $ map packageVersion pkgs) infoUrl,
                          Pages.renderDependencies render]
        -- and other package indices
        distributions <- queryPackageStatus pkgname
        -- [reverse index disabled] revCount <- revPackageSummary realpkg
        (totalDown, versionDown) <- perVersionDownloads pkg
        let distHtml = case distributions of
                [] -> []
                _  -> [("Distributions", concatHtml . intersperse (toHtml ", ") $ map showDist distributions)]
            afterHtml  = distHtml ++ [Pages.renderDownloads totalDown versionDown $ packageVersion realpkg
                                     -- [reverse index disabled] ,Pages.reversePackageSummary realpkg revr revCount
                                     ]
        -- bottom sections, currently only documentation
        hasDocs  <- queryHasDocumentation realpkg
        let docURL | hasDocs   = Just $ "/package" <//> display realpkg <//> "docs"
                   | otherwise = Nothing
        -- extra features like tags and downloads
        tags <- queryTagsForPackage pkgname

        let maintainLink = anchor ! [href $ renderResource maintainPackage [display pkgname]] << toHtml "maintain"
            tagLinks = toHtml [anchor ! [href "/packages/tags"] << "Tags", toHtml ": ",
                               toHtml (renderTags tags), toHtml " | ",
                               anchor ! [href $ renderResource tagEdit [display pkgname]] << "edit"]
            backHackage = anchor ! [href $ "http://hackage.haskell.org/package/" ++ display pkgid] << "on hackage"
        deprs <- queryGetDeprecatedFor pkgname
        let deprHtml = case deprs of
              Just fors -> paragraph ! [thestyle "color: red"] << [toHtml "Deprecated", case fors of
                [] -> noHtml
                _  -> concatHtml . (toHtml " in favor of ":) . intersperse (toHtml ", ") .
                      map (\for -> anchor ! [href $ corePackageName cores "" for] << display for) $ fors]
              Nothing -> noHtml
        -- and put it all together
        return $ toResponse $ Resource.XHtml $ haddockPage (display pkgid) $
            Pages.packagePage render [tagLinks, maintainLink, backHackage] [deprHtml] (beforeHtml ++ middleHtml ++ afterHtml) [] docURL
      where
        showDist (dname, info) = toHtml (display dname ++ ":") +++
            anchor ! [href $ distroUrl info] << toHtml (display $ distroVersion info)

    -- TODO: include delete link for admins
    serveMaintainLinks :: Resource -> Resource -> GroupResource
                       -> DynamicPath -> ServerPart Response
    serveMaintainLinks editDepr editPref mgroup dpath = htmlResponse $
                                   withPackageAllPath dpath $ \pkgname _ ->
                                   withPackageNameAuth pkgname $ \_ _ -> do
        let dpath' = [("package", display pkgname)]
        return $ toResponse $ Resource.XHtml $ hackagePage "Maintain package"
          [ unordList $
              [ anchor ! [href $ renderResource' editPref dpath'] << "Edit preferred versions"
              , anchor ! [href $ renderResource' editDepr dpath'] << "Edit deprecation"
              , anchor ! [href $ renderResource' (groupResource mgroup) dpath'] << "Maintainer list"
              ]
          ]
        -- upload documentation

{-------------------------------------------------------------------------------
  Users
-------------------------------------------------------------------------------}

data HtmlUsers = HtmlUsers {
    htmlUsersResources :: [Resource]
  }

mkHtmlUsers :: UserFeature -> HtmlUsers
mkHtmlUsers UserFeature{..} = HtmlUsers{..}
  where
    users = userResource

    htmlUsersResources = [
        -- list of users with user links; if admin, a link to add user page
        (extendResource $ userList users) {
            resourceDesc = [ (GET,  "list of users")
                           , (POST, "create a new user")
                           ]
          , resourceGet  = [ ("html", serveUserList) ]
          , resourcePost = [ ("html", \_ -> htmlResponse $ adminAddUser) ]
          }
        -- form to post to /users/
      , (resourceAt "/users/register") {
            resourceDesc = [ (GET, "show \"add user\" form") ]
          , resourceGet  = [ ("html", addUserForm) ]
          }
        -- user page with link to password form and list of groups (how to do this?)
      , (extendResource $ userPage users) {
            resourceDesc   = [ (GET,    "show user page")
                             , (DELETE, "delete the user")
                             ]
          , resourceGet    = [ ("html", serveUserPage) ]
          , resourceDelete = [ ("html", serveDeleteUser) ]
          }
        -- form to PUT password
      , (extendResource $ passwordResource users) {
            resourceDesc = [ (GET, "show password change form")
                           , (PUT, "change password")
                           ]
          , resourceGet  = [ ("html", servePasswordForm) ]
          , resourcePut  = [ ("html", servePutPassword) ]
          }
        -- form to enable or disable users (admin only)
      , (extendResource $ enabledResource users) {
            resourceDesc = [ (GET, "return if the user is enabled")
                           , (PUT, "set if the user is enabled")
                           ]
          , resourceGet  = [("html", serveEnabledForm)]
          , resourcePut  = [("html", servePutEnabled)]
          }
      ]

    serveUserList :: DynamicPath -> ServerPart Response
    serveUserList _ = do
        userlist <- Map.keys . Users.userNameMap <$> queryGetUserDb
        let hlist = unordList $ map (\uname -> anchor ! [href $ userPageUri users "" uname] << display uname) userlist
        ok $ toResponse $ Resource.XHtml $ hackagePage "Hackage users" [h2 << "Hackage users", hlist]

    serveUserPage :: DynamicPath -> ServerPart Response
    serveUserPage dpath = htmlResponse $ withUserPath dpath $ \uid info -> do
        let uname = userName info
        uris <- getGroupIndex uid
        uriPairs <- forM uris $ \uri -> do
            desc <- getIndexDesc uri
            return $ Pages.renderGroupName desc (Just uri)
        return $ toResponse $ Resource.XHtml $ hackagePage (display uname)
          [ h2 << display uname
        --, paragraph << [toHtml "[", anchor << [href $ userPasswordUri r "" uname] settings, toHtml "]"]
          , case uriPairs of
                [] -> noHtml
                _  -> toHtml
                  [ toHtml $ display uname ++ " is part of the following groups:"
                  , unordList uriPairs
                  ]
          ]

    addUserForm :: DynamicPath -> ServerPart Response
    addUserForm _ = htmlResponse $ do
        return $ toResponse $ Resource.XHtml $ hackagePage "Register account"
          [ paragraph << "Register a user account here!"
          , form ! [theclass "box", XHtml.method "post", action $ userListUri users ""] <<
                [ simpleTable [] []
                    [ makeInput [thetype "text"] "username" "User name"
                    , makeInput [thetype "password"] "password" "Password"
                    , makeInput [thetype "password"] "repeat-password" "Confirm password"
                    ]
                , paragraph << input ! [thetype "submit", value "Create user"]
                ]
          ]

    servePasswordForm :: DynamicPath -> ServerPart Response
    servePasswordForm dpath = htmlResponse $
                                withUserPath dpath $ \pathUid userInfo -> do
        users <- queryGetUserDb
        (uid, _) <- guardAuthenticated hackageRealm users
        let uname = userName userInfo
        canChange <- canChangePassword uid pathUid
        case canChange of
            False -> errForbidden "Can't change password" [MText "You're neither this user nor an admin."]
            True -> return $ toResponse $ Resource.XHtml $ hackagePage "Change password"
              [ toHtml "Change your password. You'll be prompted for authentication upon submission, if you haven't logged in already."
              , form ! [theclass "box", XHtml.method "post", action $ userPasswordUri userResource "" uname] <<
                    [ simpleTable [] []
                        [ makeInput [thetype "password"] "password" "Password"
                        , makeInput [thetype "password"] "repeat-password" "Confirm password"
                        ]
                    , paragraph << [ hidden "_method" "PUT" --method override
                                   , input ! [thetype "submit", value "Change password"] ]
                    ]
              ]

    serveEnabledForm :: DynamicPath -> ServerPart Response
    serveEnabledForm dpath = htmlResponse $
                               withUserPath dpath $ \_ userInfo -> do
        let uname = userName userInfo
        return $ toResponse $ Resource.XHtml $ hackagePage "Change user status"
        -- TODO: expose some of the functionality in changePassword function to determine if permissions are correct
        -- before serving this form (either admin or user)
          [ toHtml "Change the account status here."
          , form ! [theclass "box", XHtml.method "post", action $ userEnabledUri users "" uname] <<
                [ toHtml $ makeCheckbox (isEnabled userInfo) "enabled" "on" "Enable user account"
                , hidden "_method" "PUT" --method override
                , paragraph << input ! [thetype "submit", value "Change status"]
                ]
          ]
      where isEnabled userInfo = case userStatus userInfo of
                Active Enabled _ -> True
                _ -> False

    servePutEnabled :: DynamicPath -> ServerPart Response
    servePutEnabled dpath = htmlResponse $
                                  withUserNamePath dpath $ \uname -> do
        enabledAccount uname
        return $ toResponse $ Resource.XHtml $ hackagePage "Account status set"
            [toHtml "Account status set for ", anchor ! [href $ userPageUri users "" uname] << display uname]

    serveDeleteUser :: DynamicPath -> ServerPart Response
    serveDeleteUser dpath =
      htmlResponse $
      withUserNamePath dpath $ \uname -> do
        deleteAccount uname
        let ntitle = "Deleted user"
        return $ toResponse $ Resource.XHtml $ hackagePage ntitle [toHtml ntitle]

    servePutPassword :: DynamicPath -> ServerPart Response
    servePutPassword dpath = htmlResponse $
                                   withUserNamePath dpath $ \uname -> do
        changePassword uname
        return $ toResponse $ Resource.XHtml $ hackagePage "Changed password"
            [toHtml "Changed password for ", anchor ! [href $ userPageUri users "" uname] << display uname]

{-------------------------------------------------------------------------------
  Uploads
-------------------------------------------------------------------------------}

data HtmlUploads = HtmlUploads {
    htmlUploadsResources :: [Resource]
  }

mkHtmlUploads :: UploadFeature -> HtmlUtilities -> HtmlUploads
mkHtmlUploads UploadFeature{..} HtmlUtilities{..} = HtmlUploads{..}
  where
    uploads = uploadResource

    htmlUploadsResources = [
      -- uploads
        -- serve upload result as HTML
        (extendResource $ uploadIndexPage uploads) {
            resourceDesc = [(POST, "Upload package")]
          , resourcePost = [("html", serveUploadResult)]
          }
        -- form for uploading
      , (resourceAt "/packages/upload") {
            resourceGet = [("html", serveUploadForm)]
          }
      ]

    serveUploadForm :: DynamicPath -> ServerPart Response
    serveUploadForm _ =
      htmlResponse $ do
        return $ toResponse $ Resource.XHtml $ hackagePage "Upload package"
          [ h2 << "Upload package"
          , paragraph << [toHtml "See also the ", anchor ! [href "/upload.html"] << "upload help page", toHtml "."]
          , form ! [theclass "box", XHtml.method "post", action "/packages/", enctype "multipart/form-data"] <<
                [ input ! [thetype "file", name "package"]
                , input ! [thetype "submit", value "Upload package"]
                ]
          ]

    serveUploadResult :: DynamicPath -> ServerPart Response
    serveUploadResult _ =
      htmlResponse $ do
        res <- uploadPackage
        let warns = uploadWarnings res
            pkgid = packageId (uploadDesc res)
        return $ toResponse $ Resource.XHtml $ hackagePage "Upload successful" $
          [ paragraph << [toHtml "Successfully uploaded ", packageLink pkgid, toHtml "!"]
          ] ++ case warns of
            [] -> []
            _  -> [paragraph << "There were some warnings:", unordList warns]

{-------------------------------------------------------------------------------
  Candidates
-------------------------------------------------------------------------------}

data HtmlCandidates = HtmlCandidates {
    htmlCandidatesResources :: [Resource]
  }

mkHtmlCandidates :: CoreFeature -> UploadFeature -> VersionsFeature -> PackageCandidatesFeature -> HtmlUtilities -> HtmlCandidates
mkHtmlCandidates CoreFeature{..} UploadFeature{..} VersionsFeature{..} PackageCandidatesFeature{..} HtmlUtilities{..} = HtmlCandidates{..}
  where
    candidates  = candidatesResource

    pkgCandUploadForm = (resourceAt "/package/:package/candidate/upload") {
                            resourceGet = [("html", servePackageCandidateUpload)]
                          }
    candMaintainForm  = (resourceAt "/package/:package/candidate/maintain") {
                            resourceGet = [("html", serveCandidateMaintain)]
                          }

    htmlCandidatesResources = [
      -- candidates
        -- list of all packages which have candidates
        (extendResource $ candidatesPage candidates) {
            resourceDesc = [ (GET, "Show all package candidates")
                           , (POST, "Upload a new candidate")
                           ]
          , resourceGet  = [ ("html", serveCandidatesPage) ]
          , resourcePost = [ ("html", \_ -> htmlResponse $ postCandidate) ]
          }
        -- TODO: use custom functions, not htmlResponse
      , (extendResource $ packageCandidatesPage candidates) {
            resourceDesc = [ (GET, "Show candidate upload form")
                           , (POST, "Upload new package candidate")
                           ]
          , resourceGet  = [ ("html", servePackageCandidates pkgCandUploadForm) ]
          , resourcePost = [ ("", htmlResponse . postPackageCandidate) ]
          }
        -- package page for a candidate
      , (extendResource $ candidatePage candidates) {
            resourceDesc   = [ (GET, "Show candidate maintenance form")
                             , (PUT, "Upload new package candidate")
                             , (DELETE, "Delete a package candidate")
                             ]
          , resourceGet    = [("html", serveCandidatePage candMaintainForm)]
          , resourcePut    = [("html", htmlResponse . putPackageCandidate)]
          , resourceDelete = [("html", htmlResponse . doDeleteCandidate)]
          }
        -- form for uploading candidate
      , (resourceAt "/packages/candidates/upload") {
            resourceDesc = [ (GET, "Show package candidate upload form") ]
          , resourceGet  = [ ("html", serveCandidateUploadForm) ]
          }
        -- form for uploading candidate for a specific package version
      , pkgCandUploadForm
        -- maintenance for candidate packages
      , candMaintainForm
        -- form for publishing package
      , (extendResource $ publishPage candidates) {
           resourceDesc = [ (GET, "Show candidate publish form")
                          , (POST, "Publish a package candidate")
                          ]
         , resourceGet  = [ ("html", servePublishForm) ]
         , resourcePost = [ ("html", servePostPublish) ]
         }
      ]

    serveCandidateUploadForm :: DynamicPath -> ServerPart Response
    serveCandidateUploadForm _ =
      htmlResponse $ do
        return $ toResponse $ Resource.XHtml $ hackagePage "Checking and uploading candidates"
          [ h2 << "Checking and uploading candidates"
          , paragraph << [toHtml "See also the ", anchor ! [href "/upload.html"] << "upload help page", toHtml "."]
          , form ! [theclass "box", XHtml.method "post", action "/packages/candidates/", enctype "multipart/form-data"] <<
                [ input ! [thetype "file", name "package"]
                , input ! [thetype "submit", value "Upload candidate"]
                ]
          ]

    servePackageCandidateUpload :: DynamicPath -> ServerPart Response
    servePackageCandidateUpload _ =
      htmlResponse $ do
        return $ toResponse $ Resource.XHtml $ hackagePage "Checking and uploading candidates"
          [ form ! [theclass "box", XHtml.method "post", action "/packages/candidates/", enctype "multipart/form-data"] <<
                [ input ! [thetype "file", name "package"]
                , input ! [thetype "submit", value "Upload candidate"]
                ]
          ]

    serveCandidateMaintain :: DynamicPath -> ServerPart Response
    serveCandidateMaintain dpath =
      htmlResponse $
      withCandidatePath dpath $ \_ candidate ->
      withPackageAuth candidate $ \_ _ -> do
        return $ toResponse $ Resource.XHtml $ hackagePage "Maintain candidate"
            [toHtml "Here, you can delete a candidate, publish it, upload a new one, and edit the maintainer group."]
    {-some useful URIs here: candidateUri check "" pkgid, packageCandidatesUri check "" pkgid, publishUri check "" pkgid-}


    serveCandidatePage :: Resource -> DynamicPath -> ServerPart Response
    serveCandidatePage maintain dpath =
      htmlResponse $
      withCandidatePath dpath $ \_ cand -> do
        candRender <- liftIO $ candidateRender cand
        let PackageIdentifier pkgname version = packageId cand
            render = candPackageRender candRender
        otherVersions <- map packageVersion
                       . flip PackageIndex.lookupPackageName pkgname
                     <$> queryGetPackageIndex
        prefInfo <- queryGetPreferredInfo pkgname
        let sectionHtml = [Pages.renderVersion (packageId cand) (classifyVersions prefInfo $ insert version otherVersions) Nothing,
                           Pages.renderDependencies render] ++ Pages.renderFields render
            maintainHtml = anchor ! [href $ renderResource maintain [display $ packageId cand]] << "maintain"
        -- also utilize hasIndexedPackage :: Bool
        let warningBox = case renderWarnings candRender of
                [] -> []
                warn -> [thediv ! [theclass "notification"] << [toHtml "Warnings:", unordList warn]]
        return $ toResponse $ Resource.XHtml $ haddockPage (display $ packageId cand) $
            Pages.packagePage render [maintainHtml] warningBox sectionHtml [] Nothing

    servePublishForm :: DynamicPath -> ServerPart Response
    servePublishForm dpath = htmlResponse $
                               withCandidatePath dpath $ \_ candidate ->
                               withPackageAuth candidate $ \_ _ -> do
        let pkgid = packageId candidate
        packages <- queryGetPackageIndex
        case checkPublish packages candidate of
            Just err -> throwError err
            Nothing  -> do
                return $ toResponse $ Resource.XHtml $ hackagePage "Publishing candidates"
                    [form ! [theclass "box", XHtml.method "post", action $ publishUri candidatesResource "" pkgid]
                        << input ! [thetype "submit", value "Publish package"]]

    serveCandidatesPage :: DynamicPath -> ServerPart Response
    serveCandidatesPage _ = do
        cands <- queryGetCandidateIndex
        return $ toResponse $ Resource.XHtml $ hackagePage "Package candidates"
          [ h2 << "Package candidates"
          , paragraph <<
              [ toHtml "Here follow all the candidate package versions on Hackage. "
              , thespan ! [thestyle "color: gray"] <<
                  [ toHtml "["
                  , anchor ! [href "/packages/candidates/upload"] << "upload"
                  , toHtml "]" ]
              ]
          , unordList $ map showCands $ PackageIndex.allPackagesByName cands
          ]
        -- note: each of the lists here should be non-empty, according to PackageIndex
      where showCands pkgs =
                let desc = packageDescription . pkgDesc . candPkgInfo $ last pkgs
                    pkgname = packageName desc
                in  [ anchor ! [href $ packageCandidatesUri candidates "" pkgname ] << display pkgname
                    , toHtml ": "
                    , toHtml $ intersperse (toHtml ", ") $ flip map pkgs $ \pkg ->
                         anchor ! [href $ candidateUri candidates "" (packageId pkg)] << display (packageVersion pkg)
                    , toHtml $ ". " ++ description desc
                    ]

    servePackageCandidates :: Resource -> DynamicPath -> ServerPart Response
    servePackageCandidates candPkgUp dpath =
      htmlResponse $
      withPackageName dpath $ \pkgname ->
      withCandidates pkgname $ \_ pkgs ->
        return $ toResponse $ Resource.XHtml $ hackagePage "Package candidates" $
          [ h3 << ("Candidates for " ++ display pkgname) ] ++
          case pkgs of
            [] -> [ toHtml "No candidates exist for ", packageNameLink pkgname, toHtml ". Upload one for "
                  , anchor ! [href $ renderResource candPkgUp [display pkgname]] << "this"
                  , toHtml " or "
                  , anchor ! [href $ "/packages/candidates/upload"] << "another"
                  , toHtml " package?"
                  ]
            _  -> [ unordList $ flip map pkgs $ \pkg -> anchor ! [href $ candidateUri candidates "" $ packageId pkg] << display (packageVersion pkg) ]

    -- TODO: make publishCandidate a member of the PackageCandidates feature, just like
    -- putDeprecated and putPreferred are for the Versions feature.
    servePostPublish :: DynamicPath -> ServerPart Response
    servePostPublish dpath = htmlResponse $ do
        uresult <- publishCandidate dpath False
        return $ toResponse $ Resource.XHtml $ hackagePage "Publish successful" $
          [ paragraph << [toHtml "Successfully published ", packageLink (packageId $ uploadDesc uresult), toHtml "!"]
          ] ++ case uploadWarnings uresult of
            [] -> []
            warns -> [paragraph << "There were some warnings:", unordList warns]

{-------------------------------------------------------------------------------
  Preferred versions
-------------------------------------------------------------------------------}

data HtmlPreferred = HtmlPreferred {
    htmlPreferredResources :: [Resource]
  , editPreferred :: Resource
  , editDeprecated :: Resource
  }

mkHtmlPreferred :: CoreFeature -> VersionsFeature -> HtmlUtilities -> HtmlPreferred
mkHtmlPreferred CoreFeature{..} VersionsFeature{..} HtmlUtilities{..} = HtmlPreferred{..}
  where
    versions = versionsResource

    editDeprecated    = (resourceAt "/package/:package/deprecated/edit") {
                            resourceGet = [("html", serveDeprecateForm)]
                          }
    editPreferred     = (resourceAt "/package/:package/preferred/edit") {
                            resourceGet = [("html", servePreferForm)]
                          }

    htmlPreferredResources = [
      -- preferred versions
        editDeprecated
      , editPreferred
      , (extendResource $ preferredResource versions) {
            resourceGet = [("html", servePreferredSummary)]
          }
      , (extendResource $ preferredPackageResource versions) {
            resourceGet = [("html", servePackagePreferred editPreferred)]
          , resourcePut = [("html", servePutPreferred)]
          }
      , (extendResource $ deprecatedResource versions) {
            resourceGet = [("html", serveDeprecatedSummary)]
          }
      , (extendResource $ deprecatedPackageResource versions) {
            resourceGet = [("html", servePackageDeprecated editDeprecated)]
          , resourcePut = [("html", servePutDeprecated )]
          }
      ]

    -- This feature is in great need of a Pages module
    serveDeprecatedSummary :: DynamicPath -> ServerPart Response
    serveDeprecatedSummary _ = doDeprecatedsRender >>= \renders -> do
        return $ toResponse $ Resource.XHtml $ hackagePage "Deprecated packages"
          [ h2 << "Deprecated packages"
          , unordList $ flip map renders $ \(pkg, pkgs) -> [ packageNameLink pkg, toHtml ": ", deprecatedText pkgs ]
          ]

    deprecatedText :: [PackageName] -> Html
    deprecatedText []   = toHtml "deprecated"
    deprecatedText pkgs = toHtml
      [ toHtml "deprecated in favor of "
      , concatHtml $ intersperse (toHtml ", ") (map packageNameLink pkgs)
      ]

    servePackageDeprecated :: Resource -> DynamicPath -> ServerPart Response
    servePackageDeprecated deprEdit dpath =
      htmlResponse $
      withPackageName dpath $ \pkgname -> do
        mpkg <- doDeprecatedRender pkgname
        return $ toResponse $ Resource.XHtml $ hackagePage "Deprecated status"
          [ h2 << "Deprecated status"
          , paragraph <<
              [ toHtml $ case mpkg of
                    Nothing   -> [packageNameLink pkgname, toHtml " is not deprecated"]
                    Just pkgs -> [packageNameLink pkgname, toHtml " is ", deprecatedText pkgs]
              , thespan ! [thestyle "color: gray"] <<
                  [ toHtml " [maintainers: "
                  , anchor ! [href $ renderResource deprEdit [display pkgname]] << "edit"
                  , toHtml "]" ]
              ]
          ]

    servePreferredSummary :: DynamicPath -> ServerPart Response
    servePreferredSummary _ = doPreferredsRender >>= \renders -> do
        return $ toResponse $ Resource.XHtml $ hackagePage "Preferred versions"
          [ h2 << "Preferred versions"
          , case renders of
                [] -> paragraph << "There are no global preferred versions."
                _  -> unordList $ flip map renders $ \(pkgname, pref) ->
                    [ packageNameLink pkgname
                    ,  unordList [varList "Preferred ranges" (rendRanges pref),
                                  varList "Deprecated versions" (map display $ rendVersions pref),
                                  toHtml ["Calculated range: ", rendSumRange pref]]
                    ]
          , paragraph <<
              [ anchor ! [href "/packages/preferred-versions"] << "preferred-versions"
              , toHtml " is the text file served with every index tarball that contains this information."
              ]
          ]
      where varList summ [] = toHtml $ summ ++ ": none"
            varList summ xs = toHtml $ summ ++ ": " ++ intercalate ", " xs

    packagePrefAbout :: Maybe Resource -> PackageName -> [Html]
    packagePrefAbout maybeEdit pkgname =
      [ paragraph <<
          [ anchor ! [href $ preferredUri versions ""] << "Preferred and deprecated versions"
          , toHtml $ " can be used to influence Cabal's decisions about which versions of "
          , packageNameLink pkgname
          , toHtml " to install. If a range of versions is preferred, it means that the installer won't install a non-preferred package version unless it is explicitly specified or if it's the only choice the installer has. Deprecating a version adds a range which excludes just that version. All of this information is collected in the "
          , anchor ! [href "/packages/preferred-versions"] << "preferred-versions"
          , toHtml " file that's included in the index tarball."
          , flip (maybe noHtml) maybeEdit $ \prefEdit -> thespan ! [thestyle "color: gray"] <<
              [ toHtml " [maintainers: "
              , anchor ! [href $ renderResource prefEdit [display pkgname]] << "edit"
              , toHtml "]" ]
          ]
      , paragraph <<
          [ toHtml "If all the available versions of a package are non-preferred or deprecated, cabal-install will treat this the same as if none of them are. This feature doesn't affect whether or not to install a package, only for selecting versions after a given package has decided to be installed. "
          , anchor ! [href $ deprecatedPackageUri versions "" pkgname] << "Entire-package deprecation"
          , toHtml " is also available, but it's separate from preferred versions."
          ]
      ]

    servePackagePreferred :: Resource -> DynamicPath -> ServerPart Response
    servePackagePreferred prefEdit dpath =
            htmlResponse $
            withPackageAllPath dpath $ \pkgname pkgs -> do
        pref <- doPreferredRender pkgname
        let dtitle = display pkgname ++ ": preferred and deprecated versions"
        prefInfo <- queryGetPreferredInfo pkgname
        return $ toResponse $ Resource.XHtml $ hackagePage dtitle --needs core, preferredVersions, pkgname
          [ h2 << dtitle
          , concatHtml $ packagePrefAbout (Just prefEdit) pkgname
          , h4 << "Stored information"
          , case rendRanges pref of
                [] -> paragraph << [display pkgname ++ " has no preferred version ranges."]
                prefs -> paragraph << ["Preferred versions for " ++ display pkgname ++ ":"]
                             +++ unordList prefs
          , case rendVersions pref of
                [] -> paragraph << ["It has no deprecated versions."]
                deprs -> paragraph <<
                    [ "Explicitly deprecated versions for " ++ display pkgname ++ " include: "
                    , intercalate ", " (map display deprs)]
          , toHtml "The version range given to this package, therefore, is " +++ strong (toHtml $ rendSumRange pref)
          , h4 << "Versions affected"
          , paragraph << "Blue versions are normal versions. Green are those out of any preferred version ranges. Gray are deprecated."
          , paragraph << (snd $ Pages.renderVersion
                                    (PackageIdentifier pkgname $ Version [] [])
                                    (classifyVersions prefInfo $ map packageVersion pkgs) Nothing)
          ]

    servePutPreferred :: DynamicPath -> ServerPart Response
    servePutPreferred dpath =
      htmlResponse $
      withPackageName dpath $ \pkgname -> do
        putPreferred pkgname
        return $ toResponse $ Resource.XHtml $ hackagePage "Set preferred versions"
          [ h2 << "Set preferred versions"
          , paragraph <<
              [ toHtml "Set the "
              , anchor ! [href $ preferredPackageUri versionsResource "" pkgname] << "preferred versions"
              , toHtml " for "
              , packageNameLink pkgname
              , toHtml "."]
          ]

    servePutDeprecated :: DynamicPath -> ServerPart Response
    servePutDeprecated dpath =
            htmlResponse $
            withPackageName dpath $ \pkgname -> do
        wasDepr <- putDeprecated pkgname
        let dtitle = if wasDepr then "Package deprecated" else "Package undeprecated"
        return $ toResponse $ Resource.XHtml $ hackagePage dtitle
           [ h2 << dtitle
           , paragraph <<
              [ toHtml "Set the "
              , anchor ! [href $ deprecatedPackageUri versionsResource "" pkgname] << "deprecated status"
              , toHtml " for "
              , packageNameLink pkgname
              , toHtml "."]
           ]

    -- deprecated: checkbox, by: text field, space-separated list of packagenames
    serveDeprecateForm :: DynamicPath -> ServerPart Response
    serveDeprecateForm dpath =
      htmlResponse $
      withPackageName dpath $ \pkgname -> do
        mpkg <- doDeprecatedRender pkgname
        let (isDepr, mfield) = case mpkg of
                Just pkgs -> (True, unwords $ map display pkgs)
                Nothing -> (False, "")
        return $ toResponse $ Resource.XHtml $ hackagePage "Deprecate package"
            [paragraph << [toHtml "Configure deprecation for ", packageNameLink pkgname],
             form . ulist ! [theclass "box", XHtml.method "post", action $ deprecatedPackageUri versionsResource "" pkgname] <<
              [ hidden "_method" "PUT"
              , li . toHtml $ makeCheckbox isDepr "deprecated" "on" "Deprecate package"
              , li . toHtml $ makeInput [thetype "text", value mfield] "by" "Superseded by: " ++ [br, toHtml "(Optional; space-separated list of package names)"]
              , paragraph << input ! [thetype "submit", value "Set status"]
              ]]

    -- preferred: text box (one version range per line). deprecated: list of text boxes with same name
    servePreferForm :: DynamicPath -> ServerPart Response
    servePreferForm dpath =
      htmlResponse $
      withPackageName dpath $ \pkgname ->
      withPackageAll pkgname $ \pkgs -> do
        pref <- doPreferredRender pkgname
        let allVersions = map packageVersion pkgs
            rangesList  = rendRanges pref
            deprVersions = rendVersions pref
        return $ toResponse $ Resource.XHtml $ hackagePage "Adjust preferred versions"
            [concatHtml $ packagePrefAbout Nothing pkgname,
             form ! [theclass "box", XHtml.method "post", action $ preferredPackageUri versionsResource "" pkgname] <<
              [ hidden "_method" "PUT"
              , paragraph << "Preferred version ranges."
              , paragraph << textarea ! [name "preferred", rows $ show (4::Int), cols $ show (80::Int)] << unlines rangesList
              , paragraph << "Deprecated versions."
              , toHtml $ intersperse (toHtml " ") $ map (\v -> toHtml $ makeCheckbox (v `elem` deprVersions) "deprecated" (display v) (display v)) allVersions
              , paragraph << input ! [thetype "submit", value "Set status"]
              ]]

{-------------------------------------------------------------------------------
  Downloads
-------------------------------------------------------------------------------}

data HtmlDownloads = HtmlDownloads {
    htmlDownloadsResources :: [Resource]
  }

mkHtmlDownloads :: DownloadFeature -> HtmlUtilities -> HtmlDownloads
mkHtmlDownloads DownloadFeature{..} HtmlUtilities{..} = HtmlDownloads{..}
  where
    downs = downloadResource

    -- downloads
    htmlDownloadsResources = [
        (extendResource $ topDownloads downs) {
            resourceGet = [("html", serveDownloadTop)]
          }
      ]

    serveDownloadTop :: DynamicPath -> ServerPart Response
    serveDownloadTop _ = do
        pkgList <- liftIO $ sortedPackages
        return $ toResponse $ Resource.XHtml $ hackagePage "Total downloads" $
          [ h2 << "Downloaded packages"
          , thediv << table << downTableRows pkgList
          ]
      where
        downTableRows pkgList =
            [ tr << [ th << "Package name", th << "Downloads" ] ] ++
            [ tr ! [theclass (if odd n then "odd" else "even")] <<
                [ td << packageNameLink pkgname
                , td << [ toHtml $ (show count) ] ]
            | ((pkgname, count), n) <- zip pkgList [(1::Int)..] ]

{-------------------------------------------------------------------------------
  Tags
-------------------------------------------------------------------------------}

data HtmlTags = HtmlTags {
    htmlTagsResources :: [Resource]
  , tagEdit :: Resource
  }

mkHtmlTags :: CoreFeature -> TagsFeature -> ListFeature -> HtmlUtilities -> HtmlTags
mkHtmlTags CoreFeature{..} TagsFeature{..} ListFeature{..} HtmlUtilities{..} = HtmlTags{..}
  where
    tags = tagsResource

    tagEdit           = (resourceAt "/package/:package/tags/edit") {
                            resourceGet = [("html", serveTagsForm)]
                          }

    htmlTagsResources = [
        (extendResource $ tagsListing tags) {
            resourceGet = [("html", serveTagsListing)]
          }
      , (extendResource $ tagListing tags) {
            resourceGet = [("html", serveTagListing)]
          }
      , (extendResource $ packageTagsListing tags) {
            resourcePut = [("html", putPackageTags)], resourceGet = []
          }
      , tagEdit -- (extendResource $ packageTagsEdit tags) { resourceGet = [("html", serveTagsForm)] }
      ]

    serveTagsListing :: DynamicPath -> ServerPart Response
    serveTagsListing _ = do
        tagList <- queryGetTagList
        let withCounts = filter ((>0) . snd) . map (\(tg, pkgs) -> (tg, Set.size pkgs)) $ tagList
            countSort = sortBy (flip compare `on` snd) withCounts
        return $ toResponse $ Resource.XHtml $ hackagePage "Hackage tags" $
          [ h2 << "Hackage tags"
          , h4 << "By name"
          , paragraph ! [theclass "toc"] << (intersperse (toHtml ", ") $ map (tagItem . fst) withCounts)
          , h4 << "By frequency"
          , paragraph ! [theclass "toc"] << (intersperse (toHtml ", ") $ map (toHtml . tagCountItem) countSort)
          ]
      where tagCountItem (tg, count) =
              [ tagItem tg
              , toHtml $ " (" ++ show count ++ ")"
              ]
            tagItem tg = anchor ! [href $ tagUri tags "" tg] << display tg

    serveTagListing :: DynamicPath -> ServerPart Response
    serveTagListing dpath = withTagPath dpath $ \tg pkgnames -> do
        let tagd = "Packages tagged " ++ display tg
            itemFunc = renderItem
            pkgs = Set.toList pkgnames
        items <- liftIO $ makeItemList pkgs
        let (mtag, histogram) = Map.updateLookupWithKey (\_ _ -> Nothing) tg $ tagHistogram items
            -- make a 'related tags' section, so exclude this tag from the histogram
            count = fromMaybe 0 mtag
        return $ toResponse $ Resource.XHtml $ hackagePage tagd $
          [ h2 << tagd
          , case items of
                [] -> toHtml "No packages have this tag."
                _  -> toHtml
                  [ paragraph << [if count==1 then "1 package has" else show count ++ " packages have", " this tag."]
                  , paragraph ! [theclass "toc"] << [toHtml "Related tags: ", toHtml $ showHistogram histogram]
                  , ulist ! [theclass "packages"] << map itemFunc items ]
          ]
     where
      showHistogram hist = (++takeHtml) . intersperse (toHtml ", ") $
            map histogramEntry $ take takeAmount sortHist
        where hsize = Map.size hist
              takeAmount = max (div (hsize*2) 3) 12
              takeHtml = if takeAmount >= hsize then [] else [toHtml ", ..."]
              sortHist = sortBy (flip compare `on` snd) $ Map.toList hist
      histogramEntry (tg', count) = anchor ! [href $ tagUri tags "" tg'] << display tg' +++ (" (" ++ show count ++ ")")

    putPackageTags :: DynamicPath -> ServerPart Response
    putPackageTags dpath =
      htmlResponse $
      withPackageAllPath dpath $ \pkgname _ -> do
        putTags pkgname
        return $ toResponse $ Resource.XHtml $ hackagePage "Set tags"
            [toHtml "Put tags for ", packageNameLink pkgname]

    -- serve form for editing, to be received by putTags
    serveTagsForm :: DynamicPath -> ServerPart Response
    serveTagsForm dpath =
      htmlResponse $
      withPackageName dpath $ \pkgname -> do
        currTags <- queryTagsForPackage pkgname
        let tagsStr = concat . intersperse ", " . map display . Set.toList $ currTags
        return $ toResponse $ Resource.XHtml $ hackagePage "Edit package tags"
          [paragraph << [toHtml "Set tags for ", packageNameLink pkgname],
           form ! [theclass "box", XHtml.method "post", action $ packageTagsUri tags "" pkgname] <<
            [ hidden "_method" "PUT"
            , dlist . ddef . toHtml $ makeInput [thetype "text", value tagsStr] "tags" "Set tags to "
            , paragraph << input ! [thetype "submit", value "Set tags"]
            ]]

{-------------------------------------------------------------------------------
  Search
-------------------------------------------------------------------------------}

data HtmlSearch = HtmlSearch {
    htmlSearchResources :: [Resource]
  }

mkHtmlSearch :: NamesFeature -> ListFeature -> HtmlUtilities -> HtmlSearch
mkHtmlSearch NamesFeature{..} ListFeature{..} HtmlUtilities{..} = HtmlSearch{..}
  where
    names = namesResource

    htmlSearchResources = [
        (extendResource $ findPackageResource names) {
            resourceGet = [("html", servePackageFind)]
          }
      ]

    servePackageFind :: DynamicPath -> ServerPart Response
    servePackageFind _ = packageFindWith $ \mstr -> case mstr of
        Nothing -> return $ toResponse $ Resource.XHtml $
                            hackagePage "Text search" $ searchForm ""
        Just (str, texts) -> do
            let itemFunc = renderItem
            (exact, text) <- searchFindPackage str texts
            exactItems <- liftIO $ makeItemList exact
            textItems <- liftIO $ makeItemList text
            return $ toResponse $ Resource.XHtml $ hackagePageWith [noIndex] "Text search" $
              [ toHtml $ searchForm str
              , h2 << "Exact matches"
              , case exact of [] -> toHtml "None";
                              _ -> ulist ! [theclass "packages"] << map itemFunc exactItems
              , h2 << "Text matches"
              , case texts of
                    False -> toHtml "Try a longer word."
                    True  -> ulist ! [theclass "packages"] << map itemFunc textItems
              ]
      where searchForm str =
              [ h2 << "Text search"
              , paragraph << "Search for all package descriptions containing a given string. This looks for the search text anywhere it can find it, ignoring punctuation and letter case. It is mainly a replacement for Ctrl+F on the main packages page presently."
              , form ! [theclass "box", XHtml.method "GET", action "/packages/find"] <<
                    [ toHtml $ makeInput [value str] "name" "Look for "
                    , input ! [thetype "submit", value "Go!"]
                    ]
              , paragraph <<
                  [ toHtml "Use ", anchor ! [href "http://holumbus.fh-wedel.de/hayoo/hayoo.html"] << "Hayoo"
                  , toHtml " to search module and function names and "
                  , anchor ! [href "http://www.haskell.org/hoogle/"] << "Hoogle"
                  , toHtml " to fuzzily search type signatures and function names."]
              ]

{-------------------------------------------------------------------------------
  Groups
-------------------------------------------------------------------------------}

htmlGroupResource :: UserFeature -> GroupResource -> [Resource]
htmlGroupResource UserFeature{..} r@(GroupResource groupR userR groupGen) =
  [ (extendResource groupR) {
        resourceDesc = [ (GET, "Show list of users")
                       , (POST, "Udd a user to the group")
                       ]
      , resourceGet  = [ ("html", htmlResponse . getList) ]
      , resourcePost = [ ("html", htmlResponse . postUser) ]
      }
  , (extendResource userR) {
        resourceDesc   = [ (DELETE, "Delete a user from the group") ]
      , resourceDelete = [ ("html", htmlResponse . deleteFromGroup) ]
      }
  , (extendResourcePath "/edit" groupR) {
        resourceDesc = [ (GET, "Show edit form for the group") ]
      , resourceGet  = [ ("html", htmlResponse . getEditList) ]
      }
  ]
  where
    getList dpath = withGroup (groupGen dpath) $ \group -> do
        userDb   <- queryGetUserDb
        userlist <- liftIO . queryUserList $ group
        let unames = [ Users.idToName userDb uid
                     | uid   <- Group.enumerate userlist ]
        let baseUri = renderResource' groupR dpath
        return . toResponse . Resource.XHtml $ Pages.groupPage
            unames baseUri (False, False) (groupDesc group)
    getEditList dpath = withGroup (groupGen dpath) $ \group ->
                        withGroupEditAuth group $ \canAdd canDelete -> do
        userDb   <- queryGetUserDb
        userlist <- liftIO . queryUserList $ group
        let unames = [ Users.idToName userDb uid
                     | uid   <- Group.enumerate userlist ]
        let baseUri = renderResource' groupR dpath
        return . toResponse . Resource.XHtml $ Pages.groupPage
            unames baseUri (canAdd, canDelete) (groupDesc group)
    postUser dpath = withGroup (groupGen dpath) $ \group -> do
        groupAddUser group dpath
        goToList dpath
    deleteFromGroup dpath = withGroup (groupGen dpath) $ \group -> do
        groupDeleteUser group dpath
        goToList dpath
    withGroup group func = liftIO (groupExists group) >>= \exists -> case exists of
        False -> errNotFound "User group doesn't exist" [MText "User group doesn't exist"]
        True  -> func group
    goToList dpath = seeOther (renderResource' (groupResource r) dpath) (toResponse ())

{-------------------------------------------------------------------------------
  Util
-------------------------------------------------------------------------------}

htmlUtilities :: CoreFeature -> TagsFeature -> HtmlUtilities
htmlUtilities CoreFeature{..} TagsFeature{..} = HtmlUtilities{..}
  where
    packageLink :: PackageId -> Html
    packageLink pkgid = anchor ! [href $ corePackageUri cores "" pkgid] << display pkgid

    packageNameLink :: PackageName -> Html
    packageNameLink pkgname = anchor ! [href $ corePackageName cores "" pkgname] << display pkgname

    renderItem :: PackageItem -> Html
    renderItem item = li ! classes <<
          [ packageNameLink pkgname
          , toHtml $ " " ++ ptype (itemHasLibrary item) (itemNumExecutables item)
                         ++ ": " ++ itemDesc item
          , " (" +++ renderTags (itemTags item) +++ ")"
          ]
      where pkgname = itemName item
            ptype _ 0 = "library"
            ptype lib num = (if lib then "library and " else "")
                         ++ (case num of 1 -> "program"; _ -> "programs")
            classes = case classList of [] -> []; _ -> [theclass $ unwords classList]
            classList = (case itemDeprecated item of Nothing -> []; _ -> ["deprecated"])

    renderTags :: Set Tag -> [Html]
    renderTags tags = intersperse (toHtml ", ")
        (map (\tg -> anchor ! [href $ tagUri tagsResource "" tg] << display tg)
          $ Set.toList tags)

    cores = coreResource

data HtmlUtilities = HtmlUtilities {
    packageLink :: PackageId -> Html
  , packageNameLink :: PackageName -> Html
  , renderItem :: PackageItem -> Html
  , renderTags :: Set Tag -> [Html]
  }

htmlResponse :: ServerPartE a -> ServerPart a
htmlResponse part = runServerPartE (handleErrorResponse htmlError part)
  where
    htmlError :: ErrorResponse -> ServerPartE Response
    htmlError (ErrorResponse errCode errTitle message) =
        resp errCode $ toResponse
            $ Resource.XHtml $ hackagePage errorStr [h2 << errorStr, paragraph << errorToHtml message]
      where
        errorStr = "Error: " ++ errTitle

    errorToHtml :: [MessageSpan] -> [Html]
    errorToHtml []               = []
    errorToHtml (MText x    :xs) = toHtml x: errorToHtml xs
    errorToHtml (MLink x url:xs) = (anchor ! [href url] << x): errorToHtml xs

-- Prevents page indexing (e.g. for search pages).
noIndex :: Html
noIndex = meta ! [name "robots", content "noindex"]

(<//>) :: String -> String -> String
(<//>) = (System.FilePath.Posix.</>)
