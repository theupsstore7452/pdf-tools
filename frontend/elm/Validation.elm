module Validation exposing (number, pages, whole)


number : Float -> Float -> String -> Result String Float
number low high draft =
    case String.toFloat draft of
        Just n ->
            if String.endsWith "." draft || isNaN n || isInfinite n || n < low || n > high then
                Err "Enter a number within the allowed range."

            else
                Ok n

        Nothing ->
            Err "Enter a valid number."


whole : Int -> Int -> String -> Result String Int
whole low high draft =
    case String.toInt draft of
        Just n ->
            if n >= low && n <= high then
                Ok n

            else
                Err "Enter a whole number within the allowed range."

        Nothing ->
            Err "Enter a whole number."


pages : Int -> String -> Result String (List Int)
pages count draft =
    let
        bound value =
            whole 1 count (String.trim value)

        part value =
            case String.split "-" (String.trim value) of
                [ one ] ->
                    Result.map List.singleton (bound one)

                [ first, last ] ->
                    Result.map2 Tuple.pair (bound first) (bound last)
                        |> Result.andThen
                            (\( a, b ) ->
                                if a <= b then
                                    Ok (List.range a b)

                                else
                                    Err "Page ranges must be in ascending order."
                            )

                _ ->
                    Err "Use pages and ranges such as 1-3, 5."

        join item accumulated =
            Result.map2 (++) accumulated (part item)
    in
    String.split "," draft |> List.foldl join (Ok []) |> Result.map (\xs -> List.range 1 count |> List.filter (\n -> List.member n xs))
