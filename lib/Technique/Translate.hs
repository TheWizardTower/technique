{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-|
Given a Technique Procedure (concrete syntax tree), translate it into an
internalized representation (abstract syntax tree) that can be subsequently
executed (that is, interpreted; evaluated).
-}
module Technique.Translate where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Except (MonadError(..))
import Control.Monad.State.Class (MonadState(..))
import Control.Monad.Trans.State.Strict (StateT(..), evalStateT, execStateT, runStateT)
import Control.Monad.Trans.Except (Except(..), runExcept)
import Core.Data
import Core.Text
import Data.Foldable (foldl', traverse_)
import Data.UUID.Types (UUID)

import Technique.Builtins
import Technique.Internal
import Technique.Language
import Technique.Quantity


{-|
Environment in the type-theory sense of the word: the map(s) between names
and their bindings.
-}
data Environment = Environment
    { environmentVariables :: Map Identifier Name
    , environmentFunctions :: Map Identifier Procedure
    , environmentRole :: Attribute
    , environmentAccumulated :: Sequence
    }

newtype Translate a = Translate (StateT Environment (Except CompilerFailure) a)
    deriving (Functor, Applicative, Monad, MonadState Environment, MonadError CompilerFailure)

unTranslate :: Translate a -> StateT Environment (Except CompilerFailure) a
unTranslate (Translate r) = r
{-# INLINE unTranslate #-}

{-|
Take a static Procedure definition and spin it up into a "Subroutine"
suitable for interpretation. In other words, translate between the concrete
syntax types and the abstract syntax we can feed to an evaluator.
-}
translate :: Environment -> Procedure -> Either CompilerFailure Subroutine
translate env procedure =
  let
    block = procedureBlock procedure
    result = runTranslate env (translateBlock block)
  in
    case result of
        Left e -> Left e
        Right env' -> Right $
            Subroutine
                { subroutineSource = procedure
                , subroutineSteps = environmentAccumulated env'
                }

runTranslate :: Environment -> Translate a -> Either CompilerFailure a
runTranslate env action = runExcept (evalStateT (unTranslate action) env)

{-|
Blocks are scoping mechanisms, so accumulated environment is discarded once
we finish resolving names within it.
-}
-- traverse_ is "new", just mapM_ at Applicative? Lets see how we feel
-- about that.
translateBlock :: Block -> Translate Sequence
translateBlock (Block statements) = do
    traverse_ translateStatement statements
    env' <- get
    return (environmentAccumulated env')

translateStatement :: Statement -> Translate ()
translateStatement statement = case statement of
    Assignment vars expr -> do
        names <- traverse createVariable vars
        step <- translateExpression expr

        let step' = Asynchronous names step

        appendStep step'

    Execute expr ->
        translateExpression expr

    Declaration proc ->
        insertProcedure proc

    -- the remainder are functionally no-ops
    Comment _ -> []
    Blank -> []
    Series -> []

translateExpression :: Environment -> Expression -> [Step]
translateExpression env expr = case expr of
    Application i expr ->
        -- lookup returns a function that constructs a Step
        (lookupProcedure env i) (translateExpression env expr)
    None ->
        [Known Unitus]
    Text text ->
        [Known (Literali text)]
    Amount qty ->
        [Known (Quanticle qty)]
    Undefined ->
        error "?!?" -- TODO ERROR not error but "hole, stop here"
    Object (Tablet bindings) ->
        Known (Tabularum (fmap ( \(Binding label expr) -> (label,translateExpression env expr)) bindings)):[]
    Variable is ->
        Tuple (fmap Depends is)
    Operation op subexpr1 subexpr2 ->
      let
        f = case op of
                WaitEither  -> builtinProcedureWaitEither
                WaitBoth    -> builtinProcedureWaitBoth
                Combine     -> builtinProcedureCombineValues
      in
        External f (Tuple [(translateExpression env subexpr1),(translateExpression env subexpr2)])
    Grouping subexpr ->
        translateExpression env subexpr
    Restriction attr block ->
        applyRestriction attr (translateBlock env block)


{-|
A given procedure call can either be to a user declared in-scope procedure
or to a primative builtin. We have Invocation and External as the two Step
constructors for these cases. This lookup function returns a function which
is the appropriate constructor, partially applied.
-}
-- TODO ERROR this will be a hugely common spot for the compiler to
-- discover an error, in this case calling an unknown procedure. We'll need
-- *much* better error handling than this.
lookupProcedure :: Identifier -> Translate (Step -> Step)
lookupProcedure i = do
    env <- get
    let declared = lookupKeyValue i (environmentFunctions env)
    let known = lookupKeyValue i builtins

    case declared of
        Just s -> return (Invocation s)
        Nothing -> case known of
            Just p -> return (External p)
            Nothing -> failBecuase (CallToUnknownProcedure i)

insertProcedure :: Procedure -> ()
insertProcedure proc =
    undefined

-- the overloading of throw between MonadError / ExceptT and the GHC
-- exceptions mechansism is unfortunate. We're not throwing an exception,
-- end it's definitely not pure `error`. Wrap it for clarity.
failBecause :: CompilerFailure -> Translate a
failBecause e = throwError e

{-|
Identifiers are valid names but Names are unique, so that we can put
them into the environment map. This is where we check for reuse of an
already declared name (TODO) and given the local use of the identifier a
scope-local (or globally?) unique name.
-}
createVariable :: Identifier -> Translate Name
createVariable i = do
    env <- get
    let known = environmentVariables env
    when (containsKey i known) $ do
        failBecause (IdentifierAlreadyInUse i)

    let n = Name (singletonRope '!' <> unIdentifier i) -- TODO

    let known' = insertKeyValue i n known
    let env' = env { environmentVariables = known' }
    put env'
    return n

{-|
Accumulate a Step
-}
appendStep :: Step -> Translate ()
appendStep step = do
    env <- get
    let steps = environmentAccumulated env
    let role  = environmentRole env

    let steps' = steps <> (role,step)

    let env' = env { environmentAccumulated = steps' }
    put env'

{-|
This begins a new (more refined) scope and does *not* add its declarations
to the current environment.
-}
applyRestriction :: Attribute -> Block -> Translate Sequence
applyRestriction attr block = do
    env <- get

    let subenv = env
            { environmentRole = attr
            }

    let result = runTranslate subenv translateBlock

    case result of
        Left e -> failBecause e
        Right steps -> return steps
