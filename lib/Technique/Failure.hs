{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

{-|
Error messages from compiling.
-}
-- I generally try to avoid modules full of (only) types but these are here
-- so the can be shared in both Technique.Translate and Technique.Builtins.
module Technique.Failure where

import Prelude hiding (lines)

import Core.System.Base
import Core.System.Pretty
import Core.Text.Rope
import Core.Text.Utilities
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as OrdSet
import qualified Data.Text as T
import Data.Void
import Text.Megaparsec (PosState(..), SourcePos(..))
import Text.Megaparsec.Error
    ( ParseError(..)
    , ErrorItem(..)
    , ParseErrorBundle(..)
    )
import Text.Megaparsec.Pos (unPos)

import Technique.Language hiding (Label)
import Technique.Formatter

data Status = Ok | Failed CompilationError

instance Render Status where
    type Token Status = TechniqueToken
    colourize = colourizeTechnique
    intoDocA status = case status of
        Ok -> annotate LabelToken "ok"
        Failed e -> annotate ErrorToken "failed" <+> intoDocA e

data Source = Source
    { sourceContents :: Rope
    , sourceFilename :: FilePath
    , sourceOffset :: !Offset
    }
    deriving (Eq,Ord,Show)

instance Located Source where
    locationOf = sourceOffset

instance Render Source where
    type Token Source = TechniqueToken
    colourize = colourizeTechnique
    intoDocA source = pretty (sourceFilename source) <+> pretty (sourceOffset source)

emptySource :: Source
emptySource = Source
    { sourceContents = emptyRope
    , sourceFilename = "<undefined>"
    , sourceOffset = -1
    }

data FailureReason
    = InvalidSetup                         -- TODO placeholder
    | ParsingFailed [ErrorItem Char] [ErrorItem Char]
    | VariableAlreadyInUse Identifier
    | ProcedureAlreadyDeclared Identifier
    | CallToUnknownProcedure Identifier
    | UseOfUnknownIdentifier Identifier
    | EncounteredUndefined
    deriving Show

instance Enum FailureReason where
    fromEnum x = case x of
        InvalidSetup -> 1
        ParsingFailed _ _ -> 2
        VariableAlreadyInUse _ -> 3
        ProcedureAlreadyDeclared _ -> 4
        CallToUnknownProcedure _ -> 5
        UseOfUnknownIdentifier _ -> 6
        EncounteredUndefined -> 7
    toEnum = undefined

data CompilationError = CompilationError Source FailureReason
    deriving Show

instance Exception CompilationError

exitCodeFor :: CompilationError -> Int
exitCodeFor (CompilationError _ reason) = fromEnum reason

-- TODO upgrade this to (Doc ann) so we can get prettier error messages.

instance Render FailureReason where
    type Token FailureReason = TechniqueToken
    colourize = colourizeTechnique
    intoDocA failure = case failure of
        InvalidSetup -> "Invalid setup!"

        ParsingFailed unexpected expected ->
          let
            un = case unexpected of
                [] -> emptyDoc
                (item:_) -> "unexpected " <> formatErrorItem StepToken item <> hardline

            ex = case expected of
                [] -> emptyDoc
                items -> "expected " <> hsep (punctuate comma (fmap (formatErrorItem SymbolToken) items)) <> "."
          in
            un <> ex

        VariableAlreadyInUse i -> "Variable by the name of '" <> annotate VariableToken (intoDocA i) <> "' already defined."
        ProcedureAlreadyDeclared i -> "Procedure by the name of '" <> annotate ProcedureToken (intoDocA i) <> "' already declared."
        CallToUnknownProcedure i -> "Call to unknown procedure '" <> annotate ApplicationToken (intoDocA i) <> "'."
        UseOfUnknownIdentifier i -> "Variable '" <> annotate VariableToken (intoDocA i) <> "' not in scope."
        EncounteredUndefined -> "Encountered an " <> annotate ErrorToken "undefined" <> " marker."

{-|
ErrorItem is a bit overbearing, but we handle its /four/ cases by saying
single quotes around characters, double quotes around strings, /no/ quotes
around labels (descriptive text) and hard code the end of input and newline
cases.
-}
formatErrorItem :: TechniqueToken -> ErrorItem Char -> Doc TechniqueToken
formatErrorItem token item = case item of

-- It would appear that **prettyprinter** has a Pretty instance for
-- NonEmpty a. In this case token ~ Char so these are Strings, ish.
-- Previously we converted to Rope, but looks like we can go directly.

    Tokens tokens ->
        case NonEmpty.uncons tokens of
            (ch, Nothing) -> case ch of
                '\n' -> annotate token "newline"
                _  -> pretty '\'' <> annotate token (pretty ch) <> pretty '\''

            _ -> pretty '\"' <> annotate token (pretty tokens) <> pretty '\"'

    Label chars ->
        annotate token (pretty chars)

    EndOfInput ->
        "end of input"

numberOfCarots :: FailureReason -> Int
numberOfCarots reason = case reason of
    InvalidSetup -> 0
    ParsingFailed unexpected _ -> case unexpected of
        [] -> 1
        (item:_) -> case item of
            Tokens tokens -> NonEmpty.length tokens
            Label chars -> NonEmpty.length chars
            EndOfInput -> 1
    VariableAlreadyInUse i -> widthRope (unIdentifier i)
    ProcedureAlreadyDeclared i -> widthRope (unIdentifier i)
    CallToUnknownProcedure i -> widthRope (unIdentifier i)
    UseOfUnknownIdentifier i -> widthRope (unIdentifier i)
    EncounteredUndefined -> 1

instance Render CompilationError where
    type Token CompilationError = TechniqueToken
    colourize = colourizeTechnique
    intoDocA (CompilationError source reason) =
      let
        filename = pretty (sourceFilename source)
        contents = intoRope (sourceContents source)
        offset = sourceOffset source

-- Given an offset point where the error occured, split the input at that
-- point.

        (before,_) = splitRope offset contents
        (l,c) = calculatePositionEnd before

-- Isolate the line on which the error occured. l and c are 1-origin here,
-- so if there's only a single line (or empty file) we take that one single
-- line and then last one is also that line.

        lines = breakLines contents
        lines' = take l lines
        offending = if nullRope contents
            then emptyRope
            else last lines'

-- Now prepare for rendering. If the offending line is long trim it. Then
-- create a line with some carets which show where the problem is.

        linenum = pretty l
        colunum = pretty c
        (truncated,_) = splitRope 77 offending
        trimmed = if widthRope offending > 77 && c < 77
            then truncated <> "..."
            else offending

        padding = replicateChar (c - 1) ' '
        caroted = replicateChar (numberOfCarots reason) '^'
      in
        annotate StepToken filename <> ":" <> linenum <> ":" <> colunum <> hardline <>
        hardline <>
        pretty trimmed <> hardline <>
        pretty padding <> annotate ErrorToken (pretty caroted) <> hardline <>
        hardline <>
        intoDocA reason



{-|
When we get a failure in the parsing stage **megaparsec** returns a
ParseErrorBundle. Extract the first error message therein (later handle
more? Yeah nah), and convert it into something we can use.
-}
extractErrorBundle :: Source -> ParseErrorBundle T.Text Void -> CompilationError
extractErrorBundle source bundle =
  let
    errors = bundleErrors bundle
    first = NonEmpty.head errors
    (offset,unexpected,expected) = extractParseError first
    pstate = bundlePosState bundle
    srcpos = pstateSourcePos pstate

-- Do we need these? For all the examples we have seen the values of l0 and c0
-- are `1`. **megaparsec** delays calculation of line and column until
-- error rendering time. Perhaps we need to record this.

    l0 = unPos . sourceLine $ srcpos
    c0 = unPos . sourceColumn $ srcpos

    l = if l0 > 1 then error "Unexpected line balance" else 0
    c = if c0 > 1 then error "Unexpected columns balance" else 0

    reason = ParsingFailed unexpected expected

    source' = source
        { sourceOffset = offset + l + c
        }
  in
    CompilationError source' reason

extractParseError :: ParseError T.Text Void -> (Int,[ErrorItem Char],[ErrorItem Char])
extractParseError e = case e of
    TrivialError offset unexpected0 expected0 ->
      let
        unexpected = case unexpected0 of
            Just item -> item : []
            Nothing -> []
        expected = OrdSet.toList expected0
      in
        (offset,unexpected,expected)
    FancyError _ _ -> error "Unexpected parser error"
