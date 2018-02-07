-- | Definition of the S-Expression tokens used to encode the
-- formula for an opcode's semantics.  These S-Expressions are written
-- by DSL specifications of the opcode semantics and other methods;
-- the S-Expressions are read during Template Haskell expansion of the
-- SemMC.TH.attachSemantics to compile into the Haskell Formula
-- representation for passing semantics details to Crucible for
-- evaluation.

{-# LANGUAGE LambdaCase #-}

module SemMC.Formula.SETokens
    ( FAtom(..)
    , string, ident, quoted, int
    , fromFoldable, fromFoldable'
    , printAtom, printTokens
    , parseLL
    )
    where

import qualified Data.Foldable as F
import qualified Data.SCargot as SC
import qualified Data.SCargot.Comments as SC
import qualified Data.SCargot.Repr as SC
import           Data.Semigroup
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import qualified Text.Parsec as P
import           Text.Parsec.Text ( Parser )
import           Text.Printf ( printf )


data FAtom = AIdent String
           | AQuoted String
           | AString String
           | AInt Integer
           | ABV Int Integer
           deriving (Show)


string :: String -> SC.SExpr FAtom
string = SC.SAtom . AString

-- | Lift an unquoted identifier.
ident :: String -> SC.SExpr FAtom
ident = SC.SAtom . AIdent

-- | Lift a quoted identifier.
quoted :: String -> SC.SExpr FAtom
quoted = SC.SAtom . AQuoted

-- | Lift an integer.
int :: Integer -> SC.SExpr FAtom
int = SC.SAtom . AInt



-- * Miscellaneous operations on the S-Expressions

-- | Turn any 'Foldable' into an s-expression by transforming each element with
-- the given function, then assembling as you would expect.
fromFoldable :: (F.Foldable f) => (a -> SC.SExpr atom) -> f a -> SC.SExpr atom
fromFoldable f = F.foldr (SC.SCons . f) SC.SNil

-- | @fromFoldable id@
fromFoldable' :: (F.Foldable f) => f (SC.SExpr atom) -> SC.SExpr atom
fromFoldable' = fromFoldable id

-- * Output of the S-Expression Formula language


-- | Generates the the S-expression tokens represented by the sexpr
-- argument, preceeded by a list of strings output as comments.
printTokens :: Seq.Seq String -> SC.SExpr FAtom -> T.Text
printTokens comments sexpr =
  formatComment comments <> SC.encodeOne (SC.removeMaxWidth $ SC.basicPrint printAtom) sexpr
  -- n.b. the following is more human-readable, but *much* slower to generate
  -- formatComment comments <> SC.encodeOne (SC.setIndentAmount 1 $ SC.basicPrint printAtom) sexpr


formatComment :: Seq.Seq String -> T.Text
formatComment c
  | Seq.null c = T.empty
  | otherwise = T.pack $ unlines $ fmap formatLine (F.toList c)
  where
    formatLine l = printf ";; %s" l


printAtom :: FAtom -> T.Text
printAtom a =
  case a of
    AIdent s -> T.pack s
    AQuoted s -> T.pack ('\'' : s)
    AString s -> T.pack (show s)
    AInt i -> T.pack (show i)
    ABV w val -> formatBV w val


formatBV :: Int -> Integer -> T.Text
formatBV w val = T.pack (prefix ++ printf fmt val)
  where
    (prefix, fmt)
      | w `rem` 4 == 0 = ("#x", "%0" ++ show (w `div` 4) ++ "x")
      | otherwise = ("#b", "%0" ++ show w ++ "b")


-- * Input and parse of the S-Expression Formula language

-- | This is only the base-level parsing of atoms.  The full language
-- parsing is handled by the base here and the Parser definitions.

parseIdent :: Parser String
parseIdent = (:) <$> first <*> P.many rest
  where first = P.letter P.<|> P.oneOf "+-=<>_"
        rest = P.letter P.<|> P.digit P.<|> P.oneOf "+-=<>_"

parseString :: Parser String
parseString = do
  _ <- P.char '"'
  s <- P.many (P.noneOf ['"'])
  _ <- P.char '"'
  return s

parseBV :: Parser (Int, Integer)
parseBV = P.char '#' >> ((P.char 'b' >> parseBin) P.<|> (P.char 'x' >> parseHex))
  where parseBin = P.oneOf "10" >>= \d -> parseBin' (1, if d == '1' then 1 else 0)

        parseBin' :: (Int, Integer) -> Parser (Int, Integer)
        parseBin' (bits, x) = do
          P.optionMaybe (P.oneOf "10") >>= \case
            Just d -> parseBin' (bits + 1, x * 2 + (if d == '1' then 1 else 0))
            Nothing -> return (bits, x)

        parseHex = (\s -> (length s * 4, read ("0x" ++ s))) <$> P.many1 P.hexDigit

parseAtom :: Parser FAtom
parseAtom
  =   AIdent      <$> parseIdent
  P.<|> AQuoted     <$> (P.char '\'' >> parseIdent)
  P.<|> AString     <$> parseString
  P.<|> AInt . read <$> P.many1 P.digit
  P.<|> uncurry ABV <$> parseBV

parserLL :: SC.SExprParser FAtom (SC.SExpr FAtom)
parserLL = SC.withLispComments (SC.mkParser parseAtom)

parseLL :: T.Text -> Either String (SC.SExpr FAtom)
parseLL = SC.decodeOne parserLL
