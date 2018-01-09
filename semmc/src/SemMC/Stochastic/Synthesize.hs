{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}
-- | Description: Synthesize a program that implements a target instruction.
--
-- Stochastic synthesis as described in the STOKE and STRATA papers.
--
-- STOKE: Stochastic superoptimization:
-- https://cs.stanford.edu/people/eschkufz/docs/asplos_13.pdf
--
-- STRATA: Stratified Synthesis:
-- https://cs.stanford.edu/people/eschkufz/docs/pldi_16.pdf
module SemMC.Stochastic.Synthesize
  ( -- * API
    synthesize
    -- * Exports for testing
  , computeTargetResults
  , wrongPlacePenalty
  , weighCandidate
  ) where

import           GHC.Stack ( HasCallStack )

import           Control.Applicative
import qualified Control.Exception as C
import           Control.Monad
import           Control.Monad.Trans ( liftIO )
import qualified Data.Foldable as F
import qualified Data.Map as M
import           Data.Maybe ( catMaybes )
import           Data.Proxy ( Proxy(..) )
import qualified Data.Sequence as S
import qualified Data.Set as Set
import           Data.Typeable ( Typeable )
import qualified GHC.Err.Located as L
import           Text.Printf

import qualified Data.Set.NonEmpty as NES
import           Data.Parameterized.Classes
import           Data.Parameterized.HasRepr ( HasRepr )
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.List as SL
import qualified Data.Parameterized.TraversableFC as FC
import           Dismantle.Arbitrary as D
import qualified Dismantle.Instruction.Random as D
import qualified Dismantle.Instruction as D

import           SemMC.Architecture ( Instruction, Opcode, Operand, ShapeRepr, OperandTypeRepr )
import qualified SemMC.Architecture.Concrete as AC
import qualified SemMC.Architecture.Value as V
import qualified SemMC.Architecture.View as V
import qualified SemMC.Concrete.Execution as CE
import qualified SemMC.Stochastic.CandidateProgram as CP
import           SemMC.Stochastic.Monad
import           SemMC.Stochastic.Pseudo
                 ( Pseudo
                 , SynthOpcode
                 , SynthInstruction(..)
                 , synthArbitraryOperands
                 , synthInsnToActual
                 )
import qualified SemMC.Stochastic.IORelation as I
import qualified SemMC.Util as U
import qualified UnliftIO as U

-- | Attempt to stochastically find a program in terms of the base set that has
-- the same semantics as the given instruction.
--
-- This function can loop forever, and should be called under a timeout
synthesize :: (SynC arch, U.HasCallStack)
           => AC.RegisterizedInstruction arch
           -> Syn t arch (CP.CandidateProgram t arch)
synthesize target = do
  case target of
    AC.RI { AC.riInstruction = i0 } -> do
      nThreads <- askParallelSynth
      U.logM U.Info $
        printf "Attempting to synthesize a program for %s using %i threads"
        (show i0) nThreads
  (numRounds, candidate) <- parallelSynthOne target
  U.logM U.Info $ printf "found candidate after %i rounds" numRounds
  let candidateWithoutNops = catMaybes . F.toList $ candidate
  U.logM U.Debug $ printf "candidate:\n%s" (unlines . map show $ candidateWithoutNops)
  tests <- askTestCases
  U.logM U.Debug $ printf "number of test cases = %i\n" (length tests)
  withSymBackend $ \sym -> do
    f <- CP.programFormula sym candidateWithoutNops
    return CP.CandidateProgram { CP.cpInstructions = candidateWithoutNops
                               , CP.cpFormula = f
                               }

data SynthesisException arch = AllSynthesisThreadsFailed (Proxy arch) (Instruction arch)

deriving instance (SynC arch) => Show (SynthesisException arch)
instance (Typeable arch, SynC arch) => C.Exception (SynthesisException arch)

parallelSynthOne :: forall arch t
                  . (SynC arch, HasCallStack)
                 => AC.RegisterizedInstruction arch
                 -> Syn t arch (Integer, Candidate arch)
parallelSynthOne target = do
  nThreads <- askParallelSynth
  env <- askGlobalEnv
  asyncs <- replicateM nThreads
    (U.async $ runSynInNewLocalEnv env (mcmcSynthesizeOne target))
  snd <$> U.waitAnyCancel asyncs

-- | Get concrete execution results for the tests on a target program.
--
-- Note that this function also returns the tests with alterations required by
-- the registerization process.  The tests are paired with a unique ID that can
-- be used to correlate the tests with runs on candidate programs.
computeTargetResults :: (SynC arch)
                     => AC.RegisterizedInstruction arch
                     -> [V.ConcreteState arch]
                     -> Syn t arch ([CE.TestCase (V.ConcreteState arch) (Instruction arch)],
                                    (CE.ResultIndex (V.ConcreteState arch)))
computeTargetResults target tests = do
  let registerizedInsns = map (AC.registerizeInstruction target) tests
  tcs <- mapM (\(insn, t) -> mkTestCase t [insn]) registerizedInsns
  resultIndex <- runConcreteTests tcs
  return (tcs, resultIndex)

-- | Get concrete execution results for the tests on a candidate program.
--
-- Note that the tests should be the tests returned by 'computeTargetResults',
-- which modifies test programs as necessary due to registerization.
--
-- In addition to the result index (containing the concrete execution results),
-- we return a list of pairs of test cases.  The first element of each pair is
-- the corresponding test case from the target.  The second element of each pair
-- is the corresponding test case for the candidate.  This gives both nonces,
-- which we can use to look up results in the relevant result indexes.
computeCandidateResults :: (SynC arch)
                        => Candidate arch
                        -> [CE.TestCase (V.ConcreteState arch) (Instruction arch)]
                        -> Syn t arch ([(CE.TestCase (V.ConcreteState arch) (Instruction arch), CE.TestCase (V.ConcreteState arch) (Instruction arch))],
                                       (CE.ResultIndex (V.ConcreteState arch)))
computeCandidateResults candidate tests = do
  indexedTests <- mapM (\tc -> (tc,) <$> mkTestCase (CE.testContext tc) (candidateInstructions candidate)) tests
  resultIndex <- runConcreteTests (map snd indexedTests)
  return (indexedTests, resultIndex)

mcmcSynthesizeOne :: forall arch t
                   . (SynC arch, U.HasCallStack)
                  => AC.RegisterizedInstruction arch
                  -> Syn t arch (Integer, Candidate arch)
mcmcSynthesizeOne target = do
  -- Max length of candidate programs. Can make it a parameter if
  -- needed.
  --
  -- STOKE Figure 10 suggests using length 50.
  let progLen = 8
  candidate <- emptyCandidate progLen
  -- let candidate = fromList [Just $ actualInsnToSynth @arch target]

  tests <- askTestCases
  (targetTests, targetResults) <- computeTargetResults target tests
  cost0 <- weighCandidate target targetTests targetResults candidate
  let round0 = 0
  let mCanOpt0 = Nothing
  evolve round0 cost0 mCanOpt0 targetTests targetResults candidate
  where
    -- | Evolve the candidate until it agrees with the target on the
    -- tests.
    evolve k 0 mCanOpt _ _ candidate = do
      U.logM U.Debug "done evolving!"
      let (optRound, numRvwps) = case mCanOpt of
            -- If the rvwp optimization never applied, then say it
            -- applied with no right values in the wrong place in the
            -- same round that that we found a candidate. This lets us
            -- compute stats related to the benefit of the
            -- optimization without having to consider separate cases
            -- for when it did and did not apply.
            Nothing -> (k, 0)
            Just (o, n) -> (o, n)
      U.logM U.Info $ unlines
        [ printf "rvwp stats (num rvwps, opt round, non-opt round): (%i, %i, %i)"
          numRvwps optRound k
        , printf "rvwp speedup is %.2f."
          (fromIntegral k / fromIntegral optRound :: Double) ]
      return (k, candidate)
    evolve !k cost mCanOpt targetTests targetResults candidate = do
      candidate' <- perturb candidate
      if candidate == candidate'
      then evolve (k+1) cost mCanOpt targetTests targetResults candidate
      else do
        U.logM U.Debug $ "candidate:\n"++prettyCandidate candidate
        U.logM U.Debug $ "candidate':\n"++prettyCandidate candidate'
        U.logM U.Debug $ "cost = " ++ show cost
        -- liftIO $ showDiff candidate candidate'
        (cost'', mNumRvwps, candidate'') <-
          chooseNextCandidate target targetTests targetResults
            candidate cost candidate'
        -- Compute @Just (round, numRvwps)@ for the min round where
        -- the rvwp optimization applies.
        let mCanOpt' = (k+1,) <$> mNumRvwps
        let !mCanOpt'' = mCanOpt <|> mCanOpt'
        evolve (k+1) cost'' mCanOpt'' targetTests targetResults candidate''
{-
import qualified Data.List as L
import Control.Monad

    showDiff c c' = do
      U.logM U.Debug "===================================================="
      forM_ zipped $ \xs -> do
        U.logM U.Debug $ case xs of
          [Nothing] -> ""
          [Just i] -> "=== "++show i++"\n"
          [x,x'] -> "!!! "++show x++"\n!!! "++show x'++"\n"
          _ -> L.error "the sky is falling"
      where
        zipped = S.zipWith (\x x' -> L.nub [x,x']) c c'
-}

-- | Cumulative cost of candidate across all tests.
--
-- Returns infinity if the candidate crashes any tests.
weighCandidate :: SynC arch
               => AC.RegisterizedInstruction arch
               -> [CE.TestCase (V.ConcreteState arch) (Instruction arch)]
               -> CE.ResultIndex (V.ConcreteState arch)
               -> Candidate arch
               -> Syn t arch Double
weighCandidate target targetTests targetResults candidate = do
  (testPairs, candidateResults) <- computeCandidateResults candidate targetTests
  outMasks <- getOutMasks (AC.riInstruction target)
  -- The @sequence@ collapses the 'Maybe's.
  mRvwpss <- sequence <$>
    mapM (compareTargetToCandidate targetResults candidateResults outMasks) testPairs
  let weight = case mRvwpss of
        -- Infinity. A candidate that causes test failures is
        -- undesirable.
        Nothing -> 1 / 0
        Just rvwpss -> sum $ map rdWeight $ combineDeltas rvwpss
  return weight

prettyCandidate :: Show (SynthInstruction arch)
                => Candidate arch -> String
prettyCandidate = unlines . map (("    "++) . show) . catMaybes . F.toList

-- | Choose the new candidate if it's a better match, and with the
-- Metropolis probability otherwise.
--
-- This includes an optimization from the paper where we compute the
-- cost of the new candidate incrementally and stop as soon as we know
-- it's too expensive [STOKE Section 4]. However, since we're
-- precomputing all of the test results (with
-- 'computeCandidateResults'), it's not clear this incremental cost
-- computation is doing us any good, since computing the cost of a
-- test result is probably much cheaper than computing the test result
-- itself. In the STOKE paper, they're running the tests locally, so
-- unlike us, they don't have any latency concerns that motivate
-- batching and precomputing the test results.
--
-- Without the dubious optimization, this function would basically
-- just be a call to 'weighCandidate' and then a random choice.
chooseNextCandidate :: (SynC arch, U.HasCallStack)
                    => AC.RegisterizedInstruction arch
                    -> [CE.TestCase (V.ConcreteState arch) (Instruction arch)]
                    -> CE.ResultIndex (V.ConcreteState arch)
                    -> Candidate arch
                    -> Double
                    -> Candidate arch
                    -> Syn t arch (Double, Maybe Int, Candidate arch)
chooseNextCandidate target targetTests targetResults oldCandidate oldCost newCandidate = do
  gen <- askGen
  threshold <- liftIO $ D.uniformR (0::Double, 1) gen
  U.logM U.Debug $ printf "threshold = %f" threshold
  (testPairs0, newCandidateResults) <- computeCandidateResults newCandidate targetTests
  !outMasks <- getOutMasks (AC.riInstruction target)
  let newCost0 = 0
  let rvwpss0 = []
  let go newCost rvwpss testPairs
        -- STOKE Equation 14. Note that the min expression there
        -- is a typo, as in Equation 6, and should be a *difference*
        -- of costs in the exponent, not a *ratio* of costs.
        | newCost >= oldCost - log threshold/beta = do
            U.logM U.Debug "reject"
            return (oldCost, Nothing, oldCandidate)
        | [] <- testPairs = do
            U.logM U.Debug "accept"
            let mNumRvwps = checkIfRvwpOptimizationApplies rvwpss
            return (newCost, mNumRvwps, newCandidate)
        | (testPair:testPairs') <- testPairs = do
            -- U.logM U.Debug $ printf "%f %f" cost threshold
            mRvwps <- compareTargetToCandidate targetResults newCandidateResults outMasks testPair
            case mRvwps of
              Nothing -> return (oldCost, Nothing, oldCandidate)
              Just rvwps -> do
                -- U.logM U.Debug (show dcost)
                let newCost' = newCost + sum (map rdWeight rvwps)
                let rvwpss' = rvwps : rvwpss
                go newCost' rvwpss' testPairs'
  go newCost0 rvwpss0 testPairs0
  where
    beta = 0.1 -- STOKE Figure 10.

----------------------------------------------------------------

-- | Compute the cost, in terms of mismatch, of the candidate compared
-- to the target. STOKE Section 4.6.
--
-- Returns 'Nothing' if the candidate causes a crash. Otherwise,
-- returns a 'RvwpDelta' for each out mask. The cost of this test is
-- then the sum of the weights of the deltas.
compareTargetToCandidate :: forall arch t.
                            SynC arch
                         => CE.ResultIndex (V.ConcreteState arch)
                         -> CE.ResultIndex (V.ConcreteState arch)
                         -> [V.SemanticView arch]
                         -> ( CE.TestCase (V.ConcreteState arch) (Instruction arch)
                            , CE.TestCase (V.ConcreteState arch) (Instruction arch) )
                         -> Syn t arch (Maybe ([RvwpDelta arch]))
compareTargetToCandidate targetResultIndex candidateResultIndex outMasks (targetTest, candidateTest) = do
  let targetRes = M.lookup (CE.testNonce targetTest) (CE.riSuccesses targetResultIndex)
      candidateRes = M.lookup (CE.testNonce candidateTest) (CE.riSuccesses candidateResultIndex)
  eitherWeight <- liftIO (doComparison targetRes candidateRes `C.catches` handlers)
  case eitherWeight of
    Left e -> do
      U.logM U.Debug $ printf "error = %s" (show e)
      U.logM U.Debug $ printf "target = %s" (show targetRes)
      U.logM U.Debug $ printf "candidate = %s" (show candidateRes)
      return Nothing
    Right rvwps -> return $ Just rvwps
  where
    handlers = [ C.Handler arithHandler
               , C.Handler runnerHandler
               , C.Handler comparisonHandler
               ]
    arithHandler :: C.ArithException -> IO (Either C.SomeException a)
    arithHandler e = return (Left (C.SomeException e))
    runnerHandler :: CE.RunnerResultError -> IO (Either C.SomeException a)
    runnerHandler e = return (Left (C.SomeException e))
    comparisonHandler :: ComparisonError -> IO (Either C.SomeException a)
    comparisonHandler e = return (Left (C.SomeException e))
    doComparison mTargetRes mCandidateRes = do
      case mTargetRes of
        Just CE.TestResult { CE.resultContext = targetSt } ->
          case mCandidateRes of
            Just CE.TestResult { CE.resultContext = candidateSt } ->
              Right <$> C.evaluate (map (compareTargetOutToCandidateOut targetSt candidateSt) outMasks)
            Nothing -> C.throwIO NoCandidateResult
        Nothing -> C.throwIO NoTargetResult

data ComparisonError = NoCandidateResult
                     | NoTargetResult
                     deriving (Show)

instance C.Exception ComparisonError

-- | The masks for locations that are live out for the target instruction.
--
-- Altho the registerization process can change immediate operands of
-- the target, the out masks should never depend on the
-- immediates. So, callers of this function can just compute the out
-- masks once. Indeed, if the out masks were to change for different
-- tests, then the rvwp computation (tracking which wrong places have
-- the right value) wouldn't make sense anymore.
getOutMasks :: forall arch t. SynC arch
            => Instruction arch -> Syn t arch [V.SemanticView arch]
getOutMasks (D.Instruction opcode operands) = do
  Just ioRel <- opcodeIORelation opcode
  let outputs = Set.toList $ I.outputs ioRel
  let outputToSemView (I.ImplicitOperand i) = implicitOperandToSemView i
      outputToSemView (I.OperandRef o)      = operandRefToSemView operands o
  let semViews = map outputToSemView outputs
  return semViews
  where
    operandRefToSemView :: SL.List (Operand arch) sh -> Some (SL.Index sh) -> V.SemanticView arch
    operandRefToSemView operands' (Some index) = desc
      where
        operand = operands' SL.!! index
        Just desc = AC.operandToSemanticView (Proxy :: Proxy arch) operand

    -- Warning: here we assume that implicit operands have no
    -- congruent views, and that they always compare as ints (i.e. as
    -- vanilla bit vectors). This should be correct for the most
    -- common implicit, the flag register (XER on PPC), but could be
    -- overly restrictive for a floating point implicit.
    implicitOperandToSemView :: Some (V.View arch) -> V.SemanticView arch
    implicitOperandToSemView (Some view) = V.SemanticView
      { V.semvView = view
      , V.semvCongruentViews = []
      , V.semvDiff = V.diffInt
      }

-- | Compare the target to the candidate at a single out mask.
compareTargetOutToCandidateOut :: forall arch.
                                  (SynC arch)
                               => V.ConcreteState arch
                               -> V.ConcreteState arch
                               -> V.SemanticView arch
                               -> RvwpDelta arch
compareTargetOutToCandidateOut targetSt candidateSt
 -- Pattern match on 'V.View' to learn 'KnownNat n'.
 V.SemanticView{ semvView = semvView@(V.View _ _), ..} =
  RvwpDelta{..}
  where
    rightPlaceWeight = weigh (V.peekMS candidateSt semvView)
    wrongPlaceWeights = [ weight
              | view <- semvCongruentViews
              , let weight = weigh (V.peekMS candidateSt view) ]
    rdRvwpPlaces = map (== 0) wrongPlaceWeights
    minWrongPlaceWeight = minimum wrongPlaceWeights
    rdWeight = rightPlaceWeight `min` (minWrongPlaceWeight + wrongPlacePenalty)
    weigh candidateVal = fromIntegral $ semvDiff targetVal candidateVal
    targetVal = V.peekMS targetSt semvView

-- | The weight penalty used when looking for a candidate value in the
-- wrong location.
wrongPlacePenalty :: Double
wrongPlacePenalty = 3 -- STOKE Figure 10.

----------------------------------------------------------------

-- | Right value/wrong place (rvwp) info.
--
-- We compute these separately for each test and then combine them
-- using 'combineDeltas'. When deltas are combined, the fields below
-- become cumulative instead of per test.
data RvwpDelta arch = RvwpDelta
  { rdRvwpPlaces :: [Bool]
    -- ^ Booleans indicating whether the corresponding (by position)
    -- congruent view had the right value in the wrong place on the
    -- test.
  , rdWeight :: Double
    -- ^ Weight of candidate on the test.
  }

-- | Combine the per test deltas for each out mask into a cumulative
-- delta for each out mask.
combineDeltas :: [[RvwpDelta arch]] -> [RvwpDelta arch]
-- Note that in the @[[RvwpDelta arch]]@ input the outer list is per
-- test and the inner list is per out mask. So, we combine the outer
-- list by combining its inner lists pointwise.
combineDeltas = foldr1 (zipWith combineRvwp)
  where
    r1 `combineRvwp` r2 = RvwpDelta
      { rdWeight = rdWeight r1 + rdWeight r2
      , rdRvwpPlaces = zipWith (&&) (rdRvwpPlaces r1) (rdRvwpPlaces r2) }

-- | Check if the unimplemented rvwp optimization applies.
--
-- Returns 'Nothing' if the optimization does not apply. When the
-- optimization does apply, returns @Just k@ for @k@ the number of
-- values that occur in the wrong places.
checkIfRvwpOptimizationApplies :: U.HasCallStack
                               => [[RvwpDelta arch]] -> Maybe Int
checkIfRvwpOptimizationApplies rvwpss =
  if rvwpOptimizationApplies
  then Just numRvwps
  else Nothing
  where
    rvwps = combineDeltas rvwpss
    rvwpOptimizationApplies = allRightValuesAvailable &&
                              someRightValueInTheWrongPlace
    allRightValuesAvailable = or [ rdWeight == 0 || or rdRvwpPlaces
                                 | RvwpDelta{..} <- rvwps ]
    someRightValueInTheWrongPlace = numRvwps > 0
    -- Checking for non-zero weight is only sound when
    -- 'allRightValuesAvailable' is true.
    numRvwps = length [ () | r <- rvwps , rdWeight r /= 0 ]

----------------------------------------------------------------

-- | A candidate program.
--
-- We use 'Nothing' to represent no-ops, which we need because the
-- candidate program has fixed length during its evolution.
type Candidate arch = S.Seq (Maybe (SynthInstruction arch))

candidateInstructions :: (SynC arch) => Candidate arch -> [Instruction arch]
candidateInstructions = concatMap synthInsnToActual . catMaybes . F.toList

-- | The empty program is a sequence of no-ops.
emptyCandidate :: Int -> Syn t arch (Candidate arch)
emptyCandidate len = return $ S.replicate len Nothing

----------------------------------------------------------------

-- | Randomly perturb a candidate. STOKE Section 4.3.
perturb :: SynC arch => Candidate arch -> Syn t arch (Candidate arch)
perturb candidate = do
  gen <- askGen
  strategy <- liftIO $ D.categoricalChoose
    [ (p_c, perturbOpcode)
    , (p_o, perturbOperand)
    , (p_s, swapInstructions)
    , (p_i, perturbInstruction) ]
    gen
  strategy candidate
  where
    -- Constants from STOKE Figure 10.
    p_c = 1/6
    p_o = 1/2
    p_s = 1/6
    p_i = 1/6

-- | Replace the opcode of the given instruction with a random one of the same
-- shape.
randomizeOpcode :: (HasRepr (Opcode arch (Operand arch)) (ShapeRepr arch),
                    HasRepr (Pseudo arch (Operand arch)) (ShapeRepr arch),
                    OrdF (OperandTypeRepr arch))
                => SynthInstruction arch
                -> Syn t arch (SynthInstruction arch)
randomizeOpcode (SynthInstruction oldOpcode operands) = do
  gen <- askGen
  congruent <- CP.lookupCongruentOpcodes oldOpcode
  case S.length congruent of
    0 -> L.error "bug! The opcode being replaced should always be in the congruent set!"
    len -> do
      ix <- liftIO $ D.uniformR (0, len - 1) gen
      let !newOpcode = congruent `S.index` ix
      return (SynthInstruction newOpcode operands)

-- | Randomly replace one operand of an instruction.
--
-- FIXME: This is ripped straight out of dismantle. We should probably make the
-- one there more generic.
randomizeOperand :: (D.ArbitraryOperand (Operand arch))
                 => D.Gen
                 -> SynthInstruction arch
                 -> IO (SynthInstruction arch)
randomizeOperand gen (SynthInstruction op os) = do
  updateAt <- D.uniformR (0 :: Int, fromIntegral (FC.lengthFC os - 1)) gen
  os' <- SL.itraverse (f' (toInteger updateAt) gen) os
  return (SynthInstruction op os')
  where
    f' target g ix o
      | SL.indexValue ix == target = D.arbitraryOperand g o
      | otherwise = return o

-- | Generate a random instruction
randomInstruction :: (D.ArbitraryOperands (Opcode arch) (Operand arch),
                      D.ArbitraryOperands (Pseudo arch) (Operand arch))
                  => D.Gen
                  -> NES.Set (Some (SynthOpcode arch))
                  -> IO (SynthInstruction arch)
randomInstruction gen baseSet = do
  Some opcode <- D.choose baseSet gen
  SynthInstruction opcode <$> synthArbitraryOperands gen opcode

-- | Randomly replace an opcode with another compatible opcode, while
-- keeping the operands fixed.
perturbOpcode :: SynC arch => Candidate arch -> Syn t arch (Candidate arch)
perturbOpcode candidate = do
  gen <- askGen
  index <- liftIO $ D.uniformR (0, S.length candidate - 1) gen
  let oldInstruction = candidate `S.index` index
  newInstruction <- randomizeOpcode `mapM` oldInstruction
  return $ S.update index newInstruction candidate

-- | Randomly replace the operands, while keeping the opcode fixed.
perturbOperand :: SynC arch => Candidate arch -> Syn t arch (Candidate arch)
perturbOperand candidate = do
  gen <- askGen
  index <- liftIO $ D.uniformR (0, S.length candidate - 1) gen
  let oldInstruction = candidate `S.index` index
  newInstruction <- liftIO $ randomizeOperand gen `mapM` oldInstruction
  return $ S.update index newInstruction candidate

-- | Swap two instructions in a program.
swapInstructions :: SynC arch => Candidate arch -> Syn t arch (Candidate arch)
swapInstructions candidate = do
  gen <- askGen
  index1 <- liftIO $ D.uniformR (0, S.length candidate - 1) gen
  index2 <- liftIO $ do
    -- Avoid @index1 == index2@.
    i2 <- D.uniformR (0, S.length candidate - 2) gen
    return $ if i2 < index1 then i2 else i2+1
  let [instr1, instr2] = map (candidate `S.index`) [index1, index2]
  return $ S.update index1 instr2 $ S.update index2 instr1 candidate

-- | Replace an instruction with an unrelated instruction.
perturbInstruction :: SynC arch => Candidate arch -> Syn t arch (Candidate arch)
perturbInstruction candidate = do
  gen <- askGen
  index <- liftIO $ D.uniformR (0, S.length candidate - 1) gen
  baseSet <- askBaseSet
  newInstruction <- liftIO $ join $ D.categoricalChoose
    [ (p_u, return Nothing)
    , (1 - p_u, Just <$> randomInstruction gen baseSet) ]
    gen
  return $ S.update index newInstruction candidate
  where
    -- STOKE Figure 10.
    p_u = 1/6
