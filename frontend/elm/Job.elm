module Job exposing (Status, parse)

import Dict


type alias Status =
    { state : String, percent : Int, stage : String, filename : String, error : String }


parse : String -> Status
parse raw =
    let
        field line =
            case String.indexes "=" line |> List.head of
                Just i ->
                    ( String.left i line, String.dropLeft (i + 1) line )

                Nothing ->
                    ( "", "" )

        fields =
            Dict.fromList (List.map field (String.lines raw))

        get key =
            Dict.get key fields |> Maybe.withDefault ""
    in
    { state = get "status", percent = get "percent" |> String.toInt |> Maybe.withDefault 0, stage = get "stage", filename = get "filename", error = get "error" }
