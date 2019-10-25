{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}

import Core.Program
import Core.Text

import TechniqueUser
    ( commandCheckTechnique
    , commandFormatTechnique
    )

version :: Version
version = $(fromPackage)

main :: IO ()
main = do
    context <- configure version None (complex
        [ Command "check" "Syntax- and type-check the given procedure"
            [ Option "watch" Nothing Empty [quote|
                Watch the given procedure file and recompile if changes are detected.
              |]
            , Argument "filename" [quote|
                The file containing the code for the procedure you want to type-check.
              |]
            ]
        , Command "format" "Format the given procedure"
            [ Argument "filename" [quote|
                The file containing the code for the procedure you want to format.
              |]
            ]
        ])
    executeWith context program

program :: Program None ()
program = do
    params <- getCommandLine
    case commandNameFrom params of
        Nothing -> do
            write "Illegal state?"
            terminate 2
        Just command -> case command of
            "check"     -> commandCheckTechnique
            "format"    -> commandFormatTechnique
            _       -> do
                write "Unknown command?"
                terminate 3
