{-# LANGUAGE PatternGuards #-}
module Yi.Boot where

import Yi.Debug hiding (error)
import Yi.Kernel

import System.Console.GetOpt
import System.Environment   ( getArgs )
import System.Directory     ( getHomeDirectory )
import System.FilePath

import qualified GHC
import qualified Packages
import qualified DynFlags
import qualified Module
import qualified ObjLink
import Outputable
import Control.Monad

data Opts = Libdir String | Bindir String

options :: [OptDescr Opts]
options = [
    Option ['B']  ["libdir"]  (ReqArg Libdir "libdir") "Path to runtime libraries",
    Option ['b']  ["bindir"]  (ReqArg Bindir "bindir") "Path to runtime library binaries\n(default: libdir)"
    ]

-- the path of our GHC installation
ghcLibdir :: FilePath
ghcLibdir = GHC_LIBDIR -- See Setup.hs

-- | All the packages Yi depends on, as Cabal sees it. (see Setup.hs)
pkgOpts :: [String]
pkgOpts = YI_PKG_OPTS

-- | Create a suitable Yi Kernel, via a GHC session.
-- Also return the non-boot flags.
initialize :: IO Kernel
initialize = GHC.defaultErrorHandler DynFlags.defaultDynFlags $ do
  bootArgs <- getArgs
  let (bootFlags, _, _) = getOpt Permute options bootArgs
  let libdir = last $ YI_LIBDIR : [x | Libdir x <- bootFlags]
      bindir = last $ libdir    : [x | Bindir x <- bootFlags]
  logPutStrLn $ "Using Yi libdir: " ++ libdir
  logPutStrLn $ "Using Yi bindir: " ++ bindir
  logPutStrLn $ "Using GHC libdir: " ++ ghcLibdir
  GHC.parseStaticFlags [] -- no static flags for now
  session <- GHC.newSession (Just ghcLibdir)
  logPutStrLn $ "Session started!"
  dflags0 <- GHC.getSessionDynFlags session
  -- see GHC's Main.hs
  let dflags1 = dflags0{ GHC.ghcMode   = GHC.CompManager,
                         GHC.hscTarget = GHC.HscInterpreted,
                         GHC.ghcLink   = GHC.LinkInMemory,
                         GHC.verbosity = 1
                        }

  home <- getHomeDirectory
  let extraflags        = [ -- dubious: maybe YiConfig wants to use other pkgs: "-hide-all-packages"
                            "-i" -- clear the search directory (don't look in ./)
                          , "-i" ++ home ++ "/.yi"  -- First, we look for source files in ~/.yi
                          , "-i" ++ libdir
                          , "-odir" ++ bindir
                          , "-hidir" ++ bindir
                          , "-cpp"
                          ]
  (dflags1',_otherFlags) <- GHC.parseDynamicFlags dflags1 (pkgOpts ++ extraflags)
  (dflags2, packageIds) <- Packages.initPackages dflags1'
  logPutStrLn $ "packagesIds: " ++ (showSDocDump $ ppr $ packageIds)
  GHC.setSessionDynFlags session dflags2
  return Kernel {
                 getSessionDynFlags = GHC.getSessionDynFlags session,
                 setSessionDynFlags = GHC.setSessionDynFlags session,
                 compileExpr = GHC.compileExpr session,
                 loadAllTargets = GHC.load session GHC.LoadAllTargets,
                 setTargets = GHC.setTargets session,
                 guessTarget = GHC.guessTarget,
                 findModule = \s -> GHC.findModule session (GHC.mkModuleName s) Nothing,
                 setContext = GHC.setContext session,
                 setContextAfterLoad = setContextAfterLoadL session,
                 getNamesInScope = GHC.getNamesInScope session,
                 getRdrNamesInScope = GHC.getRdrNamesInScope session,
                 nameToString = Outputable.showSDoc . Outputable.ppr,
                 isLoaded = GHC.isLoaded session,
                 mkModuleName = Module.mkModuleName,
                 getModuleGraph = GHC.getModuleGraph session,
                 loadObjectFile = ObjLink.loadObj,
                 libraryDirectory = libdir
                }

-- | Dynamically start Yi.
startYi :: Kernel -> IO ()
startYi kernel = GHC.defaultErrorHandler DynFlags.defaultDynFlags $ do
  t <- (guessTarget kernel) "Yi.Main" Nothing
  (setTargets kernel) [t]
  loadAllTargets kernel
  yi <- join $ evalMono kernel ("Yi.Main.main :: Yi.Kernel.Kernel -> Prelude.IO ()")
  -- coerce the interpreted expression, so we check that we are not making an horrible mistake.
  logPutStrLn "Starting Yi!"
  yi kernel


setContextAfterLoadL :: GHC.Session -> IO [GHC.Module]
setContextAfterLoadL session = do
  preludeModule <- GHC.findModule session (GHC.mkModuleName "Prelude") Nothing
  graph <- GHC.getModuleGraph session
  graph' <- filterM (GHC.isLoaded session . GHC.ms_mod_name) graph
  targets <- GHC.getTargets session
  let targets' = [ m | Just m <- map (findTarget graph') targets ]
      modules = map GHC.ms_mod targets'
      context = preludeModule:modules
  GHC.setContext session [] context
  return modules
  where
  findTarget ms t =
    case filter (`matches` t) ms of
      []    -> Nothing
      (m:_) -> Just m

  summary `matches` GHC.Target (GHC.TargetModule m) _
    = GHC.ms_mod_name summary == m
  summary `matches` GHC.Target (GHC.TargetFile f _) _
    | Just f' <- GHC.ml_hs_file (GHC.ms_location summary)        = f == f'
  _summary `matches` _target
    = False
