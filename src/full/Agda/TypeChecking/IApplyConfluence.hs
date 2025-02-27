{-# LANGUAGE NondecreasingIndentation #-}
module Agda.TypeChecking.IApplyConfluence where

import Prelude hiding (null, (!!))  -- do not use partial functions like !!

import Control.Monad
import Control.Arrow (first,second)

import Data.DList (DList)
import Data.Foldable (toList)
import qualified Data.IntMap as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet

import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Internal.Generic
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Pattern

import Agda.Interaction.Options

import Agda.TypeChecking.Primitive hiding (Nat)
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Records
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Telescope.Path
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Conversion
import Agda.TypeChecking.Substitute

import qualified Agda.Utils.BiMap as BiMap
import Agda.Utils.Monad
import Agda.Utils.Null
import Agda.Utils.Maybe
import Agda.Utils.Singleton
import Agda.Utils.Size
import Agda.Utils.Impossible
import Agda.Utils.Functor


checkIApplyConfluence_ :: QName -> TCM ()
checkIApplyConfluence_ f = whenM (isJust . optCubical <$> pragmaOptions) $ do
  -- Andreas, 2019-03-27, iapply confluence should only be checked
  -- when --cubical or --erased-cubical is active. See
  -- test/Succeed/CheckIApplyConfluence.agda.
  -- We cannot reach the following crash point unless
  -- --cubical/--erased-cubical is active.
  __CRASH_WHEN__ "tc.cover.iapply.confluence.crash" 666
  reportSDoc "tc.cover.iapply" 10 $ text "Checking IApply confluence of" <+> pretty f
  inConcreteOrAbstractMode f $ \ d -> do
  case theDef d of
    Function{funClauses = cls', funCovering = cls} -> do
      reportSDoc "tc.cover.iapply" 10 $ text "length cls =" <+> pretty (length cls)
      when (null cls && any (not . null . iApplyVars . namedClausePats) cls') $
        __IMPOSSIBLE__
      modifySignature $ updateDefinition f $ updateTheDef
        $ updateCovering (const [])

      traceCall (CheckFunDefCall (getRange f) f [] False) $
        forM_ cls $ checkIApplyConfluence f
    _ -> return ()

-- | @addClause f (Clause {namedClausePats = ps})@ checks that @f ps@
-- reduces in a way that agrees with @IApply@ reductions.
checkIApplyConfluence :: QName -> Clause -> TCM ()
checkIApplyConfluence f cl = case cl of
      Clause {clauseBody = Nothing} -> return ()
      Clause {clauseType = Nothing} -> __IMPOSSIBLE__
      cl@Clause { clauseTel = clTel
                , namedClausePats = ps
                , clauseType = Just t
                , clauseBody = Just body
                } -> setCurrentRange (getRange f) $ do
          let
            trhs = unArg t
          reportSDoc "tc.cover.iapply" 40 $ "tel =" <+> prettyTCM clTel
          reportSDoc "tc.cover.iapply" 40 $ "ps =" <+> pretty ps
          ps <- normaliseProjP ps
          forM_ (iApplyVars ps) $ \ i -> do
            unview <- intervalUnview'
            let phi = unview $ IMax (argN $ unview (INeg $ argN $ var i)) $ argN $ var i
            let es = patternsToElims ps
            let lhs = Def f es

            reportSDoc "tc.iapply" 40 $ text "clause:" <+> pretty ps <+> "->" <+> pretty body
            reportSDoc "tc.iapply" 20 $ "body =" <+> prettyTCM body

            addContext clTel $ equalTermOnFace phi trhs lhs body

            case body of
              MetaV m es_m' | Just es_m <- allApplyElims es_m' ->
                caseMaybeM (isInteractionMeta m) (return ()) $ \ ii -> do
                cs' <- do
                  reportSDoc "tc.iapply.ip" 20 $ "clTel =" <+> prettyTCM clTel
                  mv <- lookupLocalMeta m
                  enterClosure (getMetaInfo mv) $ \ _ -> do -- mTel ⊢
                  ty <- getMetaType m
                  mTel <- getContextTelescope
                  reportSDoc "tc.iapply.ip" 20 $ "size mTel =" <+> pretty (size mTel)
                  reportSDoc "tc.iapply.ip" 20 $ "size es_m =" <+> pretty (size es_m)

                  unless (size mTel == size es_m) $ reportSDoc "tc.iapply.ip" 20 $ "funny number of elims" <+> text (show (size mTel, size es_m))
                  unless (size mTel <= size es_m) $ __IMPOSSIBLE__
                  let over = if size mTel == size es_m then NotOverapplied else Overapplied

                  -- extend telescope to handle extra elims
                  TelV mTel1 _ <- telViewUpToPath (size es_m) ty
                  reportSDoc "tc.iapply.ip" 20 $ "mTel1 =" <+> prettyTCM mTel1

                  addContext (mTel1 `apply` teleArgs mTel) $ do
                  mTel <- getContextTelescope

                  addContext clTel $ do -- mTel.clTel ⊢
                    () <- reportSDoc "tc.iapply.ip" 40 $ "mTel.clTel =" <+> (prettyTCM =<< getContextTelescope)
                    forallFaceMaps phi __IMPOSSIBLE__ $ \ alpha -> do
                    -- mTel.clTel' ⊢
                    -- mTel.clTel  ⊢ alpha : mTel.clTel'
                    reportSDoc "tc.iapply.ip" 40 $ "mTel.clTel' =" <+> (prettyTCM =<< getContextTelescope)

                    -- TelV tel _ <- telViewUpTo (size es) ty
                    reportSDoc "tc.iapply.ip" 40 $ "i0S =" <+> pretty alpha
                    reportSDoc "tc.iapply.ip" 20 $ fsep ["es :", pretty es]
                    reportSDoc "tc.iapply.ip" 20 $ fsep ["es_alpha :", pretty (alpha `applySubst` es) ]

                    -- reducing path applications on endpoints in lhs
                    let
                       loop t@(Def _ es) = loop' t es
                       loop t@(Var _ es) = loop' t es
                       loop t@(Con _ _ es) = loop' t es
                       loop t@(MetaV _ es) = loop' t es
                       loop t = return t
                       loop' t es = ignoreBlocking <$> (reduceIApply' (pure . notBlocked) (pure . notBlocked $ t) es)
                    lhs <- liftReduce $ traverseTermM loop (Def f (alpha `applySubst` es))

                    let
                        idG = raise (size clTel) $ (teleElims mTel [])

                    reportSDoc "tc.iapply.ip" 20 $ fsep ["lhs :", pretty lhs]
                    reportSDoc "tc.iapply.ip" 40 $ "cxt1 =" <+> (prettyTCM =<< getContextTelescope)
                    reportSDoc "tc.iapply.ip" 40 $ prettyTCM $ alpha `applySubst` ValueCmpOnFace CmpEq phi trhs lhs (MetaV m idG)

                    unifyElims (teleArgs mTel) (alpha `applySubst` es_m) $ \ sigma eqs -> do
                    -- mTel.clTel'' ⊢
                    -- mTel ⊢ clTel' ≃ clTel''.[eqs]
                    -- mTel.clTel'' ⊢ sigma : mTel.clTel'
                    reportSDoc "tc.iapply.ip" 40 $ "cxt2 =" <+> (prettyTCM =<< getContextTelescope)
                    reportSDoc "tc.iapply.ip" 40 $ "sigma =" <+> pretty sigma
                    reportSDoc "tc.iapply.ip" 20 $ "eqs =" <+> pretty eqs

                    buildClosure $ IPBoundary
                       { ipbEquations = eqs
                       , ipbValue     = sigma `applySubst` lhs
                       , ipbMetaApp   = alpha `applySubst` MetaV m es_m'
                       , ipbOverapplied = over
                       }

                    -- WAS:
                    -- fmap (over,) $ buildClosure $ (eqs
                    --                , sigma `applySubst`
                    --                    (ValueCmp CmpEq (AsTermsOf (alpha `applySubst` trhs)) lhs (alpha `applySubst` MetaV m es_m)))

                let f ip = ip { ipClause = case ipClause ip of
                                             ipc@IPClause{ipcBoundary = b}
                                               -> ipc {ipcBoundary = b ++ cs'}
                                             ipc@IPNoClause{} -> ipc}
                modifyInteractionPoints (BiMap.adjust f ii)
              _ -> return ()


-- | current context is of the form Γ.Δ
unifyElims :: Args
              -- ^ variables to keep   Γ ⊢ x_n .. x_0 : Γ
           -> Args
              -- ^ variables to solve  Γ.Δ ⊢ ts : Γ
           -> (Substitution -> [(Term,Term)] -> TCM a)
              -- Γ.Δ' ⊢ σ : Γ.Δ
              -- Γ.Δ' new current context.
              -- Γ.Δ' ⊢ [(x = u)]
              -- Γ.Δ', [(x = u)] ⊢ id_g = ts[σ] : Γ
           -> TCM a
unifyElims vs ts k = do
  dom <- getContext
  let (binds' , eqs' ) = candidate (map unArg vs) (map unArg ts)
      (binds'', eqss') =
        unzip $
        map (\(j, tts) -> case toList tts of
                t : ts -> ((j, t), map (, var j) ts)
                []     -> __IMPOSSIBLE__) $
        IntMap.toList $ IntMap.fromListWith (<>) binds'
      cod'  = codomain s (IntSet.fromList $ map fst binds'')
      cod   = cod' dom
      svs   = size vs
      binds = IntMap.fromList $
              map (second (raise (size cod - svs))) binds''
      eqs   = map (first  (raise (size dom - svs))) $
              eqs' ++ concat eqss'
      s     = bindS binds
  updateContext s cod' $ k s (s `applySubst` eqs)
  where
  candidate :: [Term] -> [Term] -> ([(Nat, DList Term)], [(Term, Term)])
  candidate is ts = case (is, ts) of
    (i : is, Var j [] : ts) -> first ((j, singleton i) :) $
                               candidate is ts
    (i : is, t : ts)        -> second ((i, t) :) $
                               candidate is ts
    ([],     [])            -> ([], [])
    _                       -> __IMPOSSIBLE__

  bindS binds = parallelS $
    case IntMap.lookupMax binds of
      Nothing       -> []
      Just (max, _) -> for [0 .. max] $ \i ->
        fromMaybe (deBruijnVar i) (IntMap.lookup i binds)

  codomain
    :: Substitution
    -> IntSet  -- Support.
    -> Context -> Context
  codomain s vs =
    mapMaybe (\(i, c) -> if i `IntSet.member` vs
                         then Nothing
                         else Just c) .
    zipWith (\i c -> (i, dropS (i + 1) s `applySubst` c)) [0..]

-- | Like @unifyElims@ but @Γ@ is from the the meta's @MetaInfo@ and
-- the context extension @Δ@ is taken from the @Closure@.
unifyElimsMeta :: MetaId -> Args -> Closure Constraint -> ([(Term,Term)] -> Constraint -> TCM a) -> TCM a
unifyElimsMeta m es_m cl k = ifM (isNothing . optCubical <$> pragmaOptions) (enterClosure cl $ k []) $ do
                  mv <- lookupLocalMeta m
                  enterClosure (getMetaInfo mv) $ \ _ -> do -- mTel ⊢
                  ty <- metaType m
                  mTel0 <- getContextTelescope
                  unless (size mTel0 == size es_m) $ reportSDoc "tc.iapply.ip.meta" 20 $ "funny number of elims" <+> text (show (size mTel0, size es_m))
                  unless (size mTel0 <= size es_m) $ __IMPOSSIBLE__ -- meta has at least enough arguments to fill its creation context.
                  reportSDoc "tc.iapply.ip.meta" 20 $ "ty: " <+> prettyTCM ty

                  -- if we have more arguments we extend the telescope accordingly.
                  TelV mTel1 _ <- telViewUpToPath (size es_m) ty
                  addContext (mTel1 `apply` teleArgs mTel0) $ do
                  mTel <- getContextTelescope
                  reportSDoc "tc.iapply.ip.meta" 20 $ "mTel: " <+> prettyTCM mTel

                  es_m <- return $ take (size mTel) es_m
                  -- invariant: size mTel == size es_m

                  (c,cxt) <- enterClosure cl $ \ c -> (c,) <$> getContextTelescope
                  reportSDoc "tc.iapply.ip.meta" 20 $ prettyTCM cxt

                  addContext cxt $ do

                  reportSDoc "tc.iapply.ip.meta" 20 $ "es_m" <+> prettyTCM es_m

                  reportSDoc "tc.iapply.ip.meta" 20 $ "trying unifyElims"

                  unifyElims (teleArgs mTel) es_m $ \ sigma eqs -> do

                  reportSDoc "tc.iapply.ip.meta" 20 $ "gotten a substitution"

                  reportSDoc "tc.iapply.ip.meta" 20 $ "sigma:" <+> prettyTCM sigma
                  reportSDoc "tc.iapply.ip.meta" 20 $ "sigma:" <+> pretty sigma

                  k eqs (sigma `applySubst` c)
