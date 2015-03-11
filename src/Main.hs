{-# LANGUAGE TemplateHaskell, TupleSections #-}

module Main where

import Control.Lens hiding (indices, op)
import Control.Applicative ((<*>))
import Control.Monad (msum)
import Control.Monad.Except (runExceptT, ExceptT)
import Control.Monad.State.Lazy (runStateT, StateT)
import System.Environment (getArgs)
import Data.Functor ((<$>))
import Data.List (isInfixOf, find, groupBy, isPrefixOf)
import Data.Maybe (fromJust, isJust)
import Data.Function (on)
import LLVM.General.Module (withModuleFromLLVMAssembly, moduleAST, File(File))
import LLVM.General.Context (withContext)
import LLVM.General.AST (Name, Named(..))
import LLVM.General.AST.Instruction (Instruction(..))
import Text.Printf
import qualified Data.Map as M
import qualified LLVM.General.AST.Constant as Constant
import qualified LLVM.General.AST as AST
import qualified LLVM.General.AST.Global as G

import RelValue

type BlockPath = [Name]

data SourceLoc = SourceLoc Int Int FilePath deriving (Eq, Ord)

instance Show SourceLoc where
  show (SourceLoc l c f) = f ++ " " ++ show l ++ ":" ++ show c

data Result = Result
  { _inOrder :: [SourceLoc]
  , _outOfOrder :: [SourceLoc]
  , _unknown :: [SourceLoc] } deriving (Eq, Ord)
noResult :: Result
noResult = Result [] [] []

instance Show Result where
  show (Result i o u) = "inorder: " ++ show i ++ "\noutoforder: " ++ show o ++ "\nunknown: " ++ show u

-- TODO: implement tracking of pointers etc inside composite data structures
data ComputationState = ComputationState
  { _numberedMetadata :: NumberedMetadata
  , _namedMetadata :: NamedMetadata
  , _intValue :: M.Map Name RelValue
  , _ptrValue :: M.Map Name (RegionKey, RelValue)
  , _lastAccess :: M.Map RegionKey RelValue
  , _availableNames :: [RelValue]
  , _availableRegions :: [RegionKey]
  , _prevBlock :: Name
  , _phiAlts :: M.Map Name Int -- TODO: implement this kind of pruning. span is a useful function. need to preserve previous phiAlts checked for the current block and make one for each
  }

type NumberedMetadata = M.Map AST.MetadataNodeID [Maybe AST.Operand]
type NamedMetadata = M.Map String [AST.MetadataNodeID]

data Function = Function [AST.Parameter] [AST.BasicBlock]

newtype RegionKey = RegionKey Int deriving (Eq, Ord)

type BlockMonad a = StateT (Result, ComputationState) Identity a

makeLenses ''ComputationState
makeLenses ''Result

simpleAnalysisString :: M.Map BlockPath Result -> String
simpleAnalysisString = fancyShow . M.unionsWith tupOr . map convert . M.elems
  where
    fancyShow :: M.Map SourceLoc [Bool] -> String
    fancyShow m = unlines $ zipWith (++) padded sProps
      where
        padded = printf ("%-" ++ show (maximum (length <$> sLocs) + 1) ++ "s") <$> sLocs
        sLocs = show <$> locs
        sProps = map (boolean 'x' '-') <$> props
        (locs, props) = unzip $ M.toList m
    convert :: Result -> M.Map SourceLoc [Bool]
    convert (Result i o u) = M.fromListWith tupOr $
      map (,[t,f,f]) i ++
      map (,[f,t,f]) o ++
      map (,[f,f,t]) u
    tupOr = zipWith (||)
    t = True
    f = False

main :: IO (M.Map Name (M.Map BlockPath Result))
main = do
  target : _ <- getArgs
  parsed <- AST.moduleDefinitions <$> readAssembly target
  let numbered = M.fromList [ (i, c) | AST.MetadataNodeDefinition i c <- parsed ]
      named = M.fromList [ (i, c) | AST.NamedMetadataDefinition i c <- parsed ]
      funcs = [ (n, Function ps bs) | (AST.GlobalDefinition AST.Function{G.parameters = (ps, _), G.name = n, G.basicBlocks = bs}) <- parsed ]
  res <- M.fromList <$> mapM (analyse numbered named) funcs
  mapM_ (\(n, m) -> print n >> putStrLn (simpleAnalysisString m)) $ M.toList res
  return res
  where
    analyse numbered named (name, f) = print name >> print (M.size res) >> prettyPrint >> return (name, res)
      where
        prettyPrint = mapM_ (\(n, r) -> putStr $ show n ++ ":\n" ++ show r ++ "\n\n") $ M.toList res
        res = simplifyPaths . M.filter nonEmpty . analyseFunction numbered named $ f
        nonEmpty (Result l1 l2 l3) = not $ all null [l1, l2, l3]

simplifyPaths :: M.Map BlockPath Result -> M.Map BlockPath Result
simplifyPaths original = M.unions $ simplify <$> partitions
  where
    partitions = map M.fromAscList . groupBy ((==) `on` head . fst) $ M.toAscList original
    simplify m = fromJust . msum $ attempt m <$> [1..]
    attempt m n = if M.fold ((&&) . isJust) True newMap then Just (fromJust <$> newMap) else Nothing
      where
        newMap = M.mapKeysWith combine (take n) $ Just <$> m
        combine a b
          | a == b = a
          | otherwise = Nothing

readAssembly :: FilePath -> IO AST.Module
readAssembly path = withContext $ \c ->
  failIO $ withModuleFromLLVMAssembly c (File path) moduleAST
runBlockMonad :: ComputationState -> BlockMonad a -> (Result, ComputationState, a)
runBlockMonad initS m = case runIdentity $ runStateT m (noResult, initS) of
  (a, (r, s)) -> (r, s, a)

analyseFunction :: NumberedMetadata -> NamedMetadata -> Function -> M.Map BlockPath Result
analyseFunction num nam (Function params (entry : blocks)) = recurse [] initState entry
  where
    recurse path@(prev : _ : _) _ b
      | [blockName b, prev] `isInfixOf` path = M.empty
    recurse path s b = case runBlockMonad s $ analyseBlock b of
      (res, state, continuations) -> M.singleton newPath res `M.union` M.unions (recurse newPath (nextstate state) <$> nextBlocks continuations)
      where
        newPath = blockName b : path
        nextBlocks continuations = fromJust . (`M.lookup` blockMap) <$> continuations
        nextstate state = state { _prevBlock = blockName b }
    initState = ComputationState num nam ints ptrs initAccess availNames availRegions undefined
    ints = M.fromList $ zip [ n | AST.Parameter (AST.IntegerType _) n _ <- params ] newNames -- TODO: not the nicest names we could have
    ptrs = M.fromList . zip [ n | AST.Parameter (AST.PointerType _ _) n _ <- params] $ zip newRegions (M.size ints `drop` newNames)
    initAccess = M.fromList . take (M.size ptrs) . zip newRegions $ M.size ints `drop` newNames
    availNames = (M.size ints + M.size ptrs) `drop` newNames
    availRegions = M.size ptrs `drop` newRegions
    newNames = Uniq <$> [0..]
    newRegions = RegionKey <$> [0..]
    blockMap = M.fromList [ (n, b) | b@(AST.BasicBlock n _ _) <- blocks ]
    blockName (AST.BasicBlock n _ _) = n
analyseFunction _ _ _ = M.empty

analyseBlock :: AST.BasicBlock -> BlockMonad [Name]
analyseBlock (AST.BasicBlock _ instr term) = mapM_ analyseInstruction instr >> cont
  where
    cont = return $ case withoutName term of
      AST.CondBr _ n1 n2 _ -> [n1, n2]
      AST.Br n _ -> [n]
      AST.Switch _ n dests _ -> n : map snd dests
      AST.IndirectBr _ ns _ -> ns
      AST.Invoke{} -> error "need function call analysis"
      _ -> []

withoutName :: Named a -> a
withoutName (Do a) = a
withoutName (_ := a) = a

biOp :: (RelValue -> RelValue -> RelValue) -> Name -> AST.Operand -> AST.Operand -> BlockMonad ()
biOp f n op1 op2 = (f <$> convertOperandToRelvalue op1 <*> convertOperandToRelvalue op2)
                   >>= setInt n

orderThreshold :: Int
orderThreshold = 1

deathAt :: Name -> String -> a
deathAt n s = error $ show n ++ ": " ++ s

analyseInstruction :: AST.Named AST.Instruction -> BlockMonad ()
analyseInstruction (n := Add _ _ op1 op2 _) = biOp (+) n op1 op2
analyseInstruction (n := Sub _ _ op1 op2 _) = biOp (-) n op1 op2
analyseInstruction (n := Mul _ _ op1 op2 _) = biOp (*) n op1 op2
analyseInstruction (n := SDiv{}) = deathAt n "(sdiv)"
analyseInstruction (n := UDiv{}) = deathAt n "(udiv)"
analyseInstruction (n := SRem{}) = deathAt n "(sdiv)"
analyseInstruction (n := URem{}) = deathAt n "(urem)"
analyseInstruction (n := And{}) = newName n >>= setInt n
analyseInstruction (n := Or{}) = newName n >>= setInt n
analyseInstruction (n := Xor{}) = newName n >>= setInt n
analyseInstruction (n := Shl _ _ op1 _ _) = convertOperandToRelvalue op1 >>= setInt n -- TODO: these are obviously not correct, but they work for a certain common case. Should detect that case and/or handle shifting correctly
analyseInstruction (n := LShr _ op1 _ _) = convertOperandToRelvalue op1 >>= setInt n
analyseInstruction (n := AShr _ op1 _ _) = convertOperandToRelvalue op1 >>= setInt n
analyseInstruction (n := Trunc{}) = newName n >>= setInt n
analyseInstruction (n := SExt op1 _ _) = convertOperandToRelvalue op1 >>= setInt n

analyseInstruction (n := Phi (AST.IntegerType{}) vals _) = do
  prev <- use $ _2 . prevBlock
  case find ((prev ==) . snd) vals of
    Nothing -> error $ "We came from " ++ show prev ++ " but that's impossible (phi int)"
    Just (AST.ConstantOperand{}, _) -> newName n >>= setInt n
    Just (op, _) -> convertOperandToRelvalue op >>= setInt n

analyseInstruction (n := Phi (AST.PointerType{}) vals _) = do
  prev <- use $ _2 . prevBlock
  case find ((prev ==) . snd) vals of
    Nothing -> error $ "We came from " ++ show prev ++ " but that's impossible (phi pointer)"
    Just (op, _) -> (fromJust <$> convertOperandToPointer op) >>= setPointer n

analyseInstruction (_ := Phi{}) = return ()

analyseInstruction (n := BitCast op (AST.PointerType{}) _)
  | opIsPointer = convertOperandToPointer op >>= (_2 . ptrValue . at n .=)
  | otherwise = newPointer n >>= setPointer n
  where
    opIsPointer = case extractType op of
      AST.PointerType{} -> True
      _ -> False

analyseInstruction (n := BitCast op (AST.IntegerType{}) _)
  | opIsInteger = convertOperandToRelvalue op >>= setInt n
  | otherwise = newName n >>= setInt n
  where
    opIsInteger = case extractType op of
      AST.IntegerType{} -> True
      _ -> False

analyseInstruction (Do Call{function = Right (AST.ConstantOperand (Constant.GlobalReference _ (AST.Name n))), arguments = args})
  | "llvm.dbg" `isPrefixOf` n = return ()
  | otherwise = mapM_ markUnknown args
  where
    markUnknown (p, _) = convertOperandToPointer p >>= maybe (return ()) mark
    mark (k, _) = newUniq >>= (_2 . lastAccess . at k ?=)
analyseInstruction (n := c@Call{function = Right callop}) = do
  analyseInstruction $ Do c
  case getReturnType $ extractType callop of
    AST.IntegerType{} -> newName n >>= setInt n
    AST.PointerType{} -> newPointer n >>= setPointer n
    _ -> return () -- TODO: for implementing struct tracking
  where
    getReturnType AST.FunctionType{AST.resultType = t} = t
    getReturnType (AST.PointerType AST.FunctionType{AST.resultType = t} _) = t

analyseInstruction (Do Store{address = ptrOp, metadata = md}) =
  getLoc md >>= analyseMemoryAccess ptrOp

analyseInstruction (n := Load{address = ptrOp, metadata = md}) = do
  getLoc md >>= analyseMemoryAccess ptrOp
  case AST.pointerReferent $ extractType ptrOp of
    AST.IntegerType{} -> newName n >>= setInt n
    AST.PointerType{} -> newPointer n >>= setPointer n

-- NOTE: this may be wrong if we do a gep on a pointer that is not the original pointer into the region
analyseInstruction (n := GetElementPtr{address = ptrOp, indices = indOps}) = do
  (k, i) <- fromJust <$> convertOperandToPointer ptrOp
  relOp <- convertOperandToRelvalue $ indOps !! indexIndex
  _2 . ptrValue . at n ?= (k, i + relOp)
  where -- NOTE: we treat pointers to arrays differently, as they are not allocated as we'd want
    indexIndex = case extractType ptrOp of
      AST.PointerType (AST.ArrayType{}) _ -> 1
      _ -> 0

analyseInstruction (n := Alloca{}) = newPointer n >>= setPointer n

analyseInstruction (Do i) | shouldIgnore = return ()
  where
    shouldIgnore = case i of
      Add{} -> True; Mul{} -> True; Sub{} -> True; UDiv{} -> True
      SDiv{} -> True; URem{} -> True; SRem{} -> True; And{} -> True
      Or{} -> True; Xor{} -> True; Shl{} -> True; LShr{} -> True; AShr{} -> True
      _ -> False

analyseInstruction i | shouldIgnore = return ()
  where
    shouldIgnore = case withoutName i of
      FAdd{} -> True; FSub{} -> True; FMul{} -> True; FDiv{} -> True; FRem{} -> True
      UIToFP{} -> True; SIToFP{} -> True; FPTrunc{} -> True; FPExt{} -> True
      ICmp{} -> True; FCmp{} -> True
      InsertElement{} -> True; InsertValue{} -> True -- TODO: when implementing struct tracking these shouldn't be ignored
      _ -> False

analyseInstruction i = error $ "unknown instruction: " ++ show i

getLoc :: [(String, AST.MetadataNode)] -> BlockMonad SourceLoc
getLoc md = case lookup "dbg" md of
  Nothing -> error $ "Couldn't find dbg in " ++ show md
  Just (AST.MetadataNode l) -> inner l
  Just (AST.MetadataNodeReference i) -> fromJust <$> use (_2 . numberedMetadata . at i) >>= inner
  where
    inner :: [Maybe AST.Operand] -> BlockMonad SourceLoc
    inner (l : c : Just scope : _) = SourceLoc (getVal l) (getVal c) <$> case scope of
      AST.MetadataNodeOperand (AST.MetadataNodeReference r) -> getStr . head <$>
        (readRef r >>= readRef . getRef . (!! 1))
    getVal (Just (AST.ConstantOperand (Constant.Int _ v))) = fromInteger v
    getStr (Just (AST.MetadataStringOperand s)) = s
    getRef (Just (AST.MetadataNodeOperand (AST.MetadataNodeReference r))) = r
    readRef r = fromJust <$> use (_2 . numberedMetadata . at r)

analyseMemoryAccess :: AST.Operand -> SourceLoc -> BlockMonad ()
analyseMemoryAccess ptrOp loc = do
  (k, i) <- fromJust <$> convertOperandToPointer ptrOp
  lastAccessI <- fromJust <$> use (_2 . lastAccess . at k)
  case fromRelValue $ i - lastAccessI of
    Nothing -> _1 . unknown %= (loc :)
    Just diff | abs diff <= orderThreshold -> _1 . inOrder %= (loc :)
    Just _ -> _1 . outOfOrder %= (loc :)
  _2 . lastAccess . at k ?= i

extractType :: AST.Operand -> AST.Type
extractType (AST.LocalReference t _) = t
extractType (AST.ConstantOperand (Constant.GlobalReference t _)) = t
extractType o = error $ "haven't implemented extractType for " ++ show o

convertOperandToRelvalue :: AST.Operand -> BlockMonad RelValue
convertOperandToRelvalue (AST.ConstantOperand c) = case c of
  Constant.Int _ v -> return $ fromInteger v
  _ -> error $ "Could not convert " ++ show c ++ " to RelValue"

convertOperandToRelvalue (AST.LocalReference _ n) = use (_2 . intValue . at n) >>= \mVal -> case mVal of
  Nothing -> error $ "Could not find value of " ++ show n
  Just val -> return val

convertOperandToPointer :: AST.Operand -> BlockMonad (Maybe (RegionKey, RelValue))
convertOperandToPointer (AST.LocalReference _ n) = use (_2 . ptrValue . at n)
convertOperandToPointer _ = return Nothing

newName :: Name -> BlockMonad RelValue
-- newName = head <$> (_2 . availableNames <<%= tail)
newName = return . Sym

newUniq :: BlockMonad RelValue
newUniq = head <$> (_2 . availableNames <<%= tail)

newRegion :: Name -> BlockMonad RegionKey
newRegion n = do
  key <- head <$> (_2 . availableRegions <<%= tail)
  newName n >>= (_2 . lastAccess . at key ?=)
  return key

newPointer :: Name -> BlockMonad (RegionKey, RelValue)
newPointer n = (,) <$> newRegion n <*> newName n

setPointer :: Name -> (RegionKey, RelValue) -> BlockMonad ()
setPointer n = (_2 . ptrValue . at n ?=)

setInt :: Name -> RelValue -> BlockMonad ()
setInt n = (_2 . intValue . at n ?=)

failIO :: Show err => ExceptT err IO a -> IO a
failIO e = runExceptT e >>= \r -> case r of
  Left err -> fail $ show err
  Right a -> return a

boolean :: a -> a -> Bool -> a
boolean a _ True = a
boolean _ a False = a
