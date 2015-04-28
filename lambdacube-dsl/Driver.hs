module Driver where

import Data.List
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Except
import Text.Show.Pretty
import System.Directory
import System.FilePath
import Debug.Trace

import qualified Type as AST
import Type hiding (ELet, EApp, ELam, EVar, ELit, ETuple, ECase, Exp, Pat, PVar, PLit, PTuple, PCon, Wildcard)
import Core
import qualified IR as IR
import qualified CoreToIR as IR
import Parser
import Typecheck hiding (Exp(..))

compileMain :: FilePath -> MName -> IO (Either String IR.Pipeline)
compileMain path fname = fmap IR.compilePipeline <$> reducedMain path fname

reducedMain :: FilePath -> MName -> IO (Either String Exp)
reducedMain path fname =
    runMM [path] $ mkReduce <$> parseAndToCoreMain fname

runMM paths = runExceptT . flip evalStateT mempty . flip runReaderT paths

parseAndToCoreMain :: MName -> MM Exp
parseAndToCoreMain m = toCore mempty <$> getDef m "main"

type Modules = [(MName, ModuleT)]

type MM = ReaderT [FilePath] (StateT Modules (ExceptT String IO))

typeCheckLC :: MName -> MM ModuleT
typeCheckLC mname = do
 c <- gets $ lookup mname
 case c of
    Just m -> return m
    _ -> do
     fnames <- asks $ map $ flip lcModuleFile mname
     let
        find [] = throwError $ "can't find module " ++ intercalate "; " fnames
        find (fname: fs) = do
         b <- liftIO $ doesFileExist fname
         if not b then find fs
         else do
          res <- liftIO $ parseLC fname
          case res of
            Left m -> throwError m
            Right (src, e) -> do
              ms <- mapM (typeCheckLC . qData) $ moduleImports e
              case joinPolyEnvs $ map exportEnv ms of
                Left m -> throwError m
                Right env -> case inference_ env e of
                    Left m    -> throwError $ m src
                    Right x   -> do
                        modify ((mname, x):)
                        return x

     find fnames

lcModuleFile path n = path </> (n ++ ".lc")

getDef :: MName -> EName -> MM (AST.Exp (Subst, Typing))
getDef m d = do
    either (\s -> throwError $ m ++ "." ++ d ++ ": " ++ s) return =<< getDef_ m d

getDef_ :: MName -> EName -> MM (Either String (AST.Exp (Subst, Typing)))
getDef_ m d = do
    typeCheckLC m
    ms <- get
    return $ case
        [ buildLet ((\ds -> [d | ValueDef d <- ds]) (concatMap (definitions . snd) (reverse dss) ++ reverse ps)) e
         | ((m', defs): dss) <- tails ms, m' == m
         , (ValueDef (AST.PVar (_, t) d', e):ps) <- tails $ reverse $ definitions defs, d' == d
         ] of
        [e] -> Right e
        [] -> Left "not found"

