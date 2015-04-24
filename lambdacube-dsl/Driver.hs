module Driver where

import Data.List
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Except
import Text.Show.Pretty
import System.Directory
import System.FilePath

import qualified Type as AST
import Type hiding (ELet, EApp, ELam, EVar, ELit, ETuple, ECase, Exp, Pat, PVar, PLit, PTuple, PCon, Wildcard)
import Core
import qualified IR as IR
import qualified CoreToIR as IR
import Parser
import Typecheck hiding (Exp(..))
import Typing (primFunMap)

compileMain :: FilePath -> MName -> IO (Either String IR.Pipeline)
compileMain path fname = fmap IR.compilePipeline <$> reducedMain path fname

reducedMain :: FilePath -> MName -> IO (Either String Exp)
reducedMain path fname =
    runMM path $ mkReduce <$> parseAndToCoreMain fname

runMM path = runExceptT . flip evalStateT mempty . flip runReaderT path

parseAndToCoreMain :: MName -> MM Exp
parseAndToCoreMain m = toCore mempty <$> getDef m "main"

type Modules = [(MName, Module (Subst, Typing))]

type MM = ReaderT FilePath (StateT Modules (ExceptT String IO))

typeCheckLC :: MName -> MM (Module (Subst, Typing))
typeCheckLC mname = do
 c <- gets $ lookup mname
 case c of
    Just m -> return m
    _ -> do
     fname <- asks $ flip lcModuleFile mname
     b <- liftIO $ doesFileExist fname
     if not b then throwError $ "can't find module " ++ fname
     else do
      res <- liftIO $ parseLC fname
      case res of
        Left m -> throwError m
        Right (src, e) -> do
          ms <- mapM (typeCheckLC . qData) $ moduleImports e
          case joinPolyEnvs $ PolyEnv primFunMap: map exportEnv ms of
            Left m -> throwError m
            Right env -> case inference_ env e of
                Left m    -> throwError $ m src
                Right x   -> do
                    modify ((mname, x):)
                    return x

lcModuleFile path n = path </> (n ++ ".lc")

getDef :: MName -> EName -> MM (AST.Exp (Subst, Typing))
getDef m d = do
    either (\s -> throwError $ m ++ "." ++ d ++ ": " ++ s) return =<< getDef_ m d Nothing

getDef_ :: MName -> EName -> Maybe Ty -> MM (Either String (AST.Exp (Subst, Typing)))
getDef_ m d mt = do
    typeCheckLC m
    ms <- get
    return $ case
        [ (buildLet (concatMap (definitions . snd) (reverse dss) ++ reverse ps) e, t)
         | ((m', defs): dss) <- tails ms, m' == m
         , ((AST.PVar (_, t) d', e):ps) <- tails $ reverse $ definitions defs, d' == d
         ] of
        [(e, t)]
            | maybe True (== typingType{-TODO: check no constr.-} t) mt -> Right e
            | otherwise -> Left $ "type is " ++ ppShow (typingType t)
        [] -> Left "not found"

