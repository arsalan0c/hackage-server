{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, RecordWildCards,
             TemplateHaskell, TypeFamilies, FlexibleInstances, MultiParamTypeClasses,
             OverloadedStrings #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.Reporting
-- Copyright   :  (c) David Waern 2008
-- License     :  BSD-like
--
-- Maintainer  :  david.waern@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Anonymous build report data structure, printing and parsing
--
-----------------------------------------------------------------------------
module Distribution.Server.Features.BuildReports.BuildReport (
    BuildReport(..),
    InstallOutcome(..),
    Outcome(..),

    -- * parsing and pretty printing
    read,
    parse,
    parseList,
    show,
    showList,

    affixTimestamp,

    BuildReport_v0,
  ) where

import Distribution.Compat.Newtype
import Distribution.Compat.Lens (Lens')
import Distribution.Package
         ( PackageIdentifier(..) )
import Distribution.Types.GenericPackageDescription
         ( FlagName, unFlagName )
import Distribution.System
         ( OS, Arch )
import Distribution.Compiler
         ( CompilerId )
import Distribution.CabalSpecVersion
         ( CabalSpecVersion(CabalSpecV2_4) )
import qualified Distribution.Pretty as Pretty
import Distribution.Pretty
         ( Pretty(..) )
import qualified Text.PrettyPrint as Disp
import Distribution.Parsec.Newtypes
import Distribution.Parsec
         ( Parsec(..), PError(..) )
import qualified Distribution.Parsec as P
import qualified Distribution.Compat.CharParsing as P
import Distribution.FieldGrammar
         ( FieldGrammar, parseFieldGrammar, prettyFieldGrammar, partitionFields
         , uniqueField, uniqueFieldAla, booleanFieldDef, monoidalFieldAla )
import Distribution.Fields.Parser
         ( readFields )
import Distribution.Fields.Pretty
         ( showFields )
import Distribution.Fields.ParseResult
         (ParseResult, parseFatalFailure, runParseResult )
import Distribution.Server.Framework.Instances ()
import Distribution.Server.Framework.MemSize

import Text.PrettyPrint.HughesPJ
         ( (<+>), render )
import Data.Serialize as Serialize
         ( Serialize(..) )
import Data.SafeCopy
         ( SafeCopy(..), deriveSafeCopy, extension, base, Migrate(..) )
import Test.QuickCheck
         ( Arbitrary(..), elements, oneof )
import Text.StringTemplate ()
import Text.StringTemplate.Classes
         ( SElem(..), ToSElem(..) )

import Data.List
         ( unfoldr )
import Data.Char as Char
         ( isAlpha, isAlphaNum )
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map as Map
import Data.Time
         ( UTCTime, getCurrentTime )
import Data.Typeable
         ( Typeable )
import Control.Applicative
import Control.Monad

import Prelude hiding (show, read)
import qualified Prelude


data BuildReport
   = BuildReport {
    -- | The package this build report is about
    package         :: PackageIdentifier,

    -- | The time at which the report was uploaded
    time            :: Maybe UTCTime,

    -- | Whether the client was generating documentation for upload
    docBuilder      :: Bool,

    -- | The OS and Arch the package was built on
    os              :: OS,
    arch            :: Arch,

    -- | The Haskell compiler (and hopefully version) used
    compiler        :: CompilerId,

    -- | The uploading client, ie cabal-install-x.y.z
    client          :: PackageIdentifier,

    -- | Which configurations flags we used
    flagAssignment  :: [(FlagName,Bool)],
    -- TODO: this is the pre-Cabal-2.2 'FlagAssignment' type;
    --       consider changing this to the new opaque 'FlagAssignment' type at some point
    --       (which will have implications for the safecopy serialisation)

    -- | Which dependent packages we were using exactly
    dependencies    :: [PackageIdentifier],

    -- | Did installing work ok?
    installOutcome  :: InstallOutcome,

    --   Which version of the Cabal library was used to compile the Setup.hs
--    cabalVersion    :: Version,

    --   Which build tools we were using (with versions)
--    tools      :: [PackageIdentifier],

    -- | Configure outcome, did configure work ok?
    docsOutcome     :: Outcome,

    -- | Configure outcome, did configure work ok?
    testsOutcome    :: Outcome
  }
  deriving (Eq, Typeable, Show)

packageL :: Lens' BuildReport PackageIdentifier
packageL f s = fmap (\x -> s { package = x }) (f (package s))

timeL :: Lens' BuildReport (Maybe UTCTime)
timeL f s = fmap (\x -> s { time = x }) (f (time s))

docBuilderL :: Lens' BuildReport Bool
docBuilderL f s = fmap (\x -> s { docBuilder = x }) (f (docBuilder s))

osL :: Lens' BuildReport OS
osL f s = fmap (\x -> s { os = x }) (f (os s))

archL :: Lens' BuildReport Arch
archL f s = fmap (\x -> s { arch = x }) (f (arch s))

compilerL :: Lens' BuildReport CompilerId
compilerL f s = fmap (\x -> s { compiler = x }) (f (compiler s))

clientL :: Lens' BuildReport PackageIdentifier
clientL f s = fmap (\x -> s { client = x }) (f (client s))

flagAssignmentL :: Lens' BuildReport [(FlagName,Bool)]
flagAssignmentL f s = fmap (\x -> s { flagAssignment = x }) (f (flagAssignment s))

dependenciesL :: Lens' BuildReport [PackageIdentifier]
dependenciesL f s = fmap (\x -> s { dependencies = x }) (f (dependencies s))

installOutcomeL :: Lens' BuildReport InstallOutcome
installOutcomeL f s = fmap (\x -> s { installOutcome = x }) (f (installOutcome s))

docsOutcomeL :: Lens' BuildReport Outcome
docsOutcomeL f s = fmap (\x -> s { docsOutcome = x }) (f (docsOutcome s))

testsOutcomeL :: Lens' BuildReport Outcome
testsOutcomeL f s = fmap (\x -> s { testsOutcome = x }) (f (testsOutcome s))

data InstallOutcome
   = PlanningFailed
   | DependencyFailed PackageIdentifier
   | DownloadFailed
   | UnpackFailed
   | SetupFailed
   | ConfigureFailed
   | BuildFailed
   | InstallFailed
   | InstallOk
   deriving (Eq, Ord, Show)

data Outcome = NotTried | Failed | Ok deriving (Eq, Ord, Show)

-- -----------------------------------------------------------------------------
-- Timestamps

-- | If the 'time' field is empty, fill it in with the current time.
affixTimestamp :: BuildReport -> IO BuildReport
affixTimestamp report = case time report of
    Nothing -> (\v -> report { time = Just v }) <$> getCurrentTime
    Just _ -> return report

-- -----------------------------------------------------------------------------
-- Parsing

read :: BS.ByteString -> BuildReport
read s = case parse s of
  Left  err -> error $ "error parsing build report: " ++ err
  Right rpt -> rpt

parse :: BS.ByteString -> Either String BuildReport
parse s = case snd $ runParseResult $ parseFields s of
  Left (_, perrors) -> Left $ unlines [ err | PError _ err <- perrors ]
  Right report -> Right report

parseFields :: BS.ByteString -> ParseResult BuildReport
parseFields input = do
  fields <- either (parseFatalFailure P.zeroPos . Prelude.show) pure $ readFields input
  case partitionFields fields of
    (fields', [])  -> parseFieldGrammar CabalSpecV2_4 fields' fieldDescrs
    _otherwise -> fail "found sections in BuildReport"

parseList :: BS.ByteString -> [BuildReport]
parseList str =
  [ report | Right report <- map parse (split str) ]

  where
    split :: BS.ByteString -> [BS.ByteString]
    split = filter (not . BS.null) . unfoldr chunk . BS.lines
    chunk [] = Nothing
    chunk ls = case break BS.null ls of
                 (r, rs) -> Just (BS.unlines r, dropWhile BS.null rs)

-- -----------------------------------------------------------------------------
-- Pretty-printing

show :: BuildReport -> String
show = showFields (const []) . prettyFieldGrammar CabalSpecV2_4 fieldDescrs

-- -----------------------------------------------------------------------------
-- Description of the fields, for parsing/printing

newtype Time = Time (Maybe UTCTime)

instance Newtype (Maybe UTCTime) Time
instance Pretty Time -- TODO
instance Parsec Time -- TODO

fieldDescrs :: (Applicative (g BuildReport), FieldGrammar g) => g BuildReport BuildReport
fieldDescrs =
  BuildReport
    <$> uniqueField       "package"            packageL
    <*> uniqueFieldAla    "time"      (pack' Time)     timeL
    <*> booleanFieldDef   "doc-builder"        docBuilderL  False
    <*> uniqueField       "os"                 osL
    <*> uniqueField       "arch"               archL
    <*> uniqueField       "compiler"           compilerL
    <*> uniqueField       "client"             clientL
    <*> undefined --monoidalFieldAla  "flags"              (alaList CommaFSep) flagAssignmentL TODO
    <*> monoidalFieldAla  "dependencies"       (alaList VCat)   dependenciesL
    <*> uniqueField       "install-outcome"    installOutcomeL
    <*> uniqueField       "docs-outcome"       docsOutcomeL
    <*> uniqueField       "tests-outcome"      testsOutcomeL

dispFlag :: (FlagName, Bool) -> Disp.Doc
dispFlag (fn, True)  =                       Disp.text (unFlagName fn)
dispFlag (fn, False) = Disp.char '-' Disp.<> Disp.text (unFlagName fn)

instance Pretty InstallOutcome where
  pretty PlanningFailed  = Disp.text "PlanningFailed"
  pretty (DependencyFailed pkgid) = Disp.text "DependencyFailed" <+> Pretty.pretty pkgid
  pretty DownloadFailed  = Disp.text "DownloadFailed"
  pretty UnpackFailed    = Disp.text "UnpackFailed"
  pretty SetupFailed     = Disp.text "SetupFailed"
  pretty ConfigureFailed = Disp.text "ConfigureFailed"
  pretty BuildFailed     = Disp.text "BuildFailed"
  pretty InstallFailed   = Disp.text "InstallFailed"
  pretty InstallOk       = Disp.text "InstallOk"

instance Parsec InstallOutcome where
  parsec = do
    name <- P.munch1 Char.isAlphaNum
    case name of
      "PlanningFailed"   -> return PlanningFailed
      "DependencyFailed" -> do P.spaces
                               pkgid <- P.parsec
                               return (DependencyFailed pkgid)
      "DownloadFailed"   -> return DownloadFailed
      "UnpackFailed"     -> return UnpackFailed
      "SetupFailed"      -> return SetupFailed
      "ConfigureFailed"  -> return ConfigureFailed
      "BuildFailed"      -> return BuildFailed
      "InstallFailed"    -> return InstallFailed
      "InstallOk"        -> return InstallOk
      _                  -> fail "unknown InstallOutcome"

instance Pretty Outcome where
  pretty NotTried = Disp.text "NotTried"
  pretty Failed   = Disp.text "Failed"
  pretty Ok       = Disp.text "Ok"

instance Parsec Outcome where
  parsec = do
    name <- P.munch1 Char.isAlpha
    case name of
      "NotTried" -> return NotTried
      "Failed"   -> return Failed
      "Ok"       -> return Ok
      _          -> fail "unknown Outcome"

instance MemSize BuildReport where
    memSize (BuildReport a b c d e f g h i j k l) = memSize10 a b c d e f g h i j + memSize k + memSize l

instance MemSize InstallOutcome where
    memSize (DependencyFailed a) = memSize1 a
    memSize _                    = memSize0

instance MemSize Outcome where
    memSize _ = memSize0

-------------------
-- HStringTemplate instances
--

instance ToSElem BuildReport where
    toSElem BuildReport{..} = SM . Map.fromList $
        [ ("package", display package)
        , ("time", toSElem time)
        , ("docBuilder", toSElem docBuilder)
        , ("os", display os)
        , ("arch", display arch)
        , ("compiler", display compiler)
        , ("client", display client)
        , ("flagAssignment", toSElem $ map (render . dispFlag) flagAssignment)
        , ("dependencies", toSElem $ map Pretty.prettyShow dependencies)
        , ("installOutcome", display installOutcome)
        , ("docsOutcome", display docsOutcome)
        , ("testsOutcome", display testsOutcome)
        ]
      where
        display value = toSElem (Pretty.prettyShow value)

-------------------
-- Arbitrary instances
--

instance Arbitrary BuildReport where
  arbitrary = BuildReport <$> arbitrary <*> arbitrary <*> arbitrary
                          <*> arbitrary <*> arbitrary <*> arbitrary
                          <*> arbitrary <*> arbitrary <*> arbitrary
                          <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary InstallOutcome where
  arbitrary = oneof [ pure PlanningFailed
                    , pure DependencyFailed <*> arbitrary
                    , pure DownloadFailed
                    , pure UnpackFailed
                    , pure SetupFailed
                    , pure ConfigureFailed
                    , pure BuildFailed
                    , pure InstallFailed
                    , pure InstallOk
                    ]

instance Arbitrary Outcome where
  arbitrary = elements [ NotTried, Failed, Ok ]


-------------------
-- SafeCopy instances
--

deriveSafeCopy 0 'base      ''Outcome
deriveSafeCopy 1 'extension ''InstallOutcome
deriveSafeCopy 3 'extension ''BuildReport


-------------------
-- Old SafeCopy versions
--

-- Note this is kind of backwards from a migration pov, but this is because
-- the oldest one used a textual external rep with a parser, and the only
-- version we have with a parser is the latest, but they're sufficiently
-- compatible that we can get away with it for now.
newtype BuildReport_v0 = BuildReport_v0 BuildReport

instance SafeCopy  BuildReport_v0
instance Serialize BuildReport_v0 where
    put (BuildReport_v0 br) = Serialize.put . BS.pack . show $ br
    get = (BuildReport_v0 . read) `fmap` Serialize.get

instance Migrate BuildReport_v1 where
    type MigrateFrom BuildReport_v1 = BuildReport_v0
    migrate (BuildReport_v0 BuildReport{..}) = BuildReport_v1 {
        v1_package = package
      , v1_os = os
      , v1_arch = arch
      , v1_compiler = compiler
      , v1_client = client
      , v1_flagAssignment = flagAssignment
      , v1_dependencies = dependencies
      , v1_installOutcome = case installOutcome of
          PlanningFailed         -> error "impossible rev migration"
          DependencyFailed pkgid -> V0_DependencyFailed pkgid
          DownloadFailed         -> V0_DownloadFailed
          UnpackFailed           -> V0_UnpackFailed
          SetupFailed            -> V0_SetupFailed
          ConfigureFailed        -> V0_ConfigureFailed
          BuildFailed            -> V0_BuildFailed
          InstallFailed          -> V0_InstallFailed
          InstallOk              -> V0_InstallOk
      , v1_docsOutcome = docsOutcome
      , v1_testsOutcome = testsOutcome
      }

data BuildReport_v1 = BuildReport_v1 {
    v1_package         :: PackageIdentifier,
    v1_os              :: OS,
    v1_arch            :: Arch,
    v1_compiler        :: CompilerId,
    v1_client          :: PackageIdentifier,
    v1_flagAssignment  :: [(FlagName,Bool)],
    v1_dependencies    :: [PackageIdentifier],
    v1_installOutcome  :: InstallOutcome_v0,
    v1_docsOutcome     :: Outcome,
    v1_testsOutcome    :: Outcome
  }

data InstallOutcome_v0
   = V0_DependencyFailed PackageIdentifier
   | V0_DownloadFailed
   | V0_UnpackFailed
   | V0_SetupFailed
   | V0_ConfigureFailed
   | V0_BuildFailed
   | V0_InstallFailed
   | V0_InstallOk

deriveSafeCopy 0 'base      ''InstallOutcome_v0
deriveSafeCopy 2 'extension ''BuildReport_v1

instance Migrate BuildReport where
    type MigrateFrom BuildReport = BuildReport_v1
    migrate BuildReport_v1{..} = BuildReport {
        package = v1_package
      , time = Nothing
      , docBuilder = True  -- Most old reports come from the doc builder anyway
      , os = v1_os
      , arch = v1_arch
      , compiler = v1_compiler
      , client = v1_client
      , flagAssignment = v1_flagAssignment
      , dependencies = v1_dependencies
      , installOutcome = migrate v1_installOutcome
      , docsOutcome = v1_docsOutcome
      , testsOutcome = v1_testsOutcome
      }

instance Migrate InstallOutcome where
    type MigrateFrom InstallOutcome = InstallOutcome_v0
    migrate outcome = case outcome of
        V0_DependencyFailed pkgid -> DependencyFailed pkgid
        V0_DownloadFailed -> DownloadFailed
        V0_UnpackFailed -> UnpackFailed
        V0_SetupFailed -> SetupFailed
        V0_ConfigureFailed -> ConfigureFailed
        V0_BuildFailed -> BuildFailed
        V0_InstallFailed -> InstallFailed
        V0_InstallOk -> InstallOk
