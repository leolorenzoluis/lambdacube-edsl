{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
module Core where

import qualified Data.Foldable as F
import Data.Char
import Data.Traversable
import Data.Monoid
import Data.Maybe
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Control.Applicative
import Control.Arrow
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Except
import Data.Foldable (Foldable, toList)
import Debug.Trace

import Pretty
import Type
import Typecheck

-------------------------------------------------------------------------------- reduce to Head Normal Form

reduceHNF :: Thunk -> Either String Thunk'       -- Left: pattern match failure
reduceHNF th@(peelThunk -> exp) = case exp of

    PrimFun f acc 0 -> Right $ mkThunk' $ evalPrimFun f $ map reduce $ reverse acc

    ENext_ -> Left "? err"
    EAlts_ 0 (map reduceHNF -> es) -> case [e | Right e <- es] of
        (thu:_) -> Right thu
        [] -> error $ "pattern match failure " ++ show [err | Left err <- es]
    EVar_ v -> case v of
        VarE v _t
          | isConstr v -> keep
          | otherwise -> {-trace (ppShow v ++ ppShow (Map.keys $ envMap th)) $ -} maybe keep reduceHNF $ join $ Map.lookup v $ envMap th
    ELet_ p x e -> case matchPattern (recEnv p x) p of
        Left err -> Left err
        Right (Just m') -> reduceHNF $ applyEnvBefore m' e
        Right _ -> keep

    EApp_ f x -> reduceHNF' f $ \f -> case f of

        PrimFun f acc i | i > 0 -> Right $ PrimFun f (x: acc) (i-1)

        ExtractInstance acc 0 n -> reduceHNF' x $ \case
            EType_ (Ty _ (Witness (WInstance m))) -> reduceHNF $ foldl (EApp' mempty) (m Map.! n) $ reverse acc
            x -> error $ "expected instance witness instead of " ++ ppShow x
        ExtractInstance acc j n -> Right $ ExtractInstance (x: acc) (j-1) n

        EAlts_ i es | i > 0 -> reduceHNF $ thunk $ EAlts_ (i-1) $ thunk . (`EApp_` x) <$> es
        EFieldProj_ fi -> reduceHNF' x $ \case
            ERecord_ fs -> case [e | (fi', e) <- fs, fi' == fi] of
                [e] -> reduceHNF e
            _ -> keep

        ELam_ p e -> case p of
            PVar (VarE v _k) -> reduceHNF' x $ \case
                EType_ x -> reduceHNF $ applySubst (Map.singleton v x) e
                _  -> case matchPattern x p of
                    Left err -> Left err
                    Right (Just m') -> reduceHNF $ applyEnvBefore m' e
                    Right _ -> keep
            _ -> case matchPattern x p of
                Left err -> Left err
                Right (Just m') -> reduceHNF $ applyEnvBefore m' e
                Right _ -> keep

        _ -> keep
    _ -> keep
  where
    keep = Right exp

reduceHNF' x f = case reduceHNF x of
    Left e -> Left e
    Right t -> f t

-- TODO: make this more efficient (memoize reduced expressions)
matchPattern :: Thunk -> Pat -> Either String (Maybe TEnv)       -- Left: pattern match failure; Right Nothing: can't reduce
matchPattern e = \case
    Wildcard -> Right $ Just mempty
    PVar (VarE v _) -> Right $ Just $ TEnv mempty $ Map.singleton v (Just e)
    PTuple ps -> reduceHNF' e $ \e -> case e of
        ETuple_ xs -> fmap mconcat . sequence <$> sequence (zipWith matchPattern xs ps)
        _ -> Right Nothing
    PCon (VarE c _) ps -> case getApp [] e of
        Left err -> Left err
        Right Nothing -> Right Nothing
        Right (Just (xx, xs)) -> case xx of
          EVar_ (VarE c' _)
            | c == c' -> fmap mconcat . sequence <$> sequence (zipWith matchPattern xs ps)
            | otherwise -> Left $ "constructors doesn't match: " ++ ppShow (c, c')
          q -> error $ "match rj: " ++ ppShow q
    p -> error $ "matchPattern: " ++ ppShow p
  where
    getApp acc e = reduceHNF' e $ \e -> case e of
        EApp_ a b -> getApp (b: acc) a
        EVar_ (VarE n _) | isConstr n -> Right $ Just (e, acc)
        _ -> Right Nothing

-------------------------------------------------------------------------------- full reduction

mkReduce :: Exp -> Exp
mkReduce = reduce . mkThunk

reduce :: Thunk -> Exp
reduce = either (error "pattern match failure.") id . reduceEither

reduce' p = reduce . applyEnvBefore (TEnv mempty $ Map.fromList [(v, Nothing) | v <- patternEVars p])

reduceEither :: Thunk -> Either String Exp
reduceEither e = reduceHNF' e $ \e -> Right $ case e of
    ELam_ p e -> ELam p $ reduce' p e
    ELet_ p x e' -> ELet p (reduce' p x) $ reduce' p e'
    EAlts_ i es -> case [e | Right e <- reduceEither <$> es] of
        [e] -> e
        es -> EAlts i es
    e -> Exp'' $ reduce <$> e


--------------------------------------------------------------------------------

evalPrimFun :: Name -> [Exp] -> Exp
evalPrimFun (ExpN x) = case x of
    "primIntToFloat" -> \[_, ELit (LInt i)] -> ELit $ LFloat $ fromIntegral i
    x -> error $ "evalPrimFun: " ++ x
