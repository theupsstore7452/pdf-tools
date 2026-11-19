module YardSigns exposing (tests)

import Expect
import Http
import Json.Encode as E
import Main
import Model exposing (..)
import Test exposing (..)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import View


step : Msg -> Model -> Model
step msg =
    Main.update msg >> Tuple.first


chosen : Model
chosen =
    Main.init "light" |> Tuple.first |> step (ChooseTool YardSign)


tests : Test
tests =
    describe "Yard Signs"
        [ test "Finished dimensions accept fractions and enforce the bleed-inclusive limit" <|
            \_ ->
                Expect.equal [ True, True, False, False, False, False, False ]
                    (List.map validYardDimension [ "18.25", "199.5", "0", "-1", "", "199.51", "Infinity" ])
        , test "Each preset supplies its finished width and height in selection order" <|
            \_ ->
                List.map (\key -> chosen |> step (Field "yard-size" key) |> yardDimensions) [ "18x24", "24x18", "24x36", "36x24" ]
                    |> Expect.equal [ ( "18", "24" ), ( "24", "18" ), ( "24", "36" ), ( "36", "24" ) ]
        , test "Custom dimensions survive switching to a preset and back" <|
            \_ ->
                chosen |> step (Field "yard-size" "custom") |> step (Field "yard-width" "12.5") |> step (Field "yard-height" "9") |> step (Field "yard-size" "36x24") |> step (Field "yard-size" "custom") |> yardDimensions |> Expect.equal ( "12.5", "9" )
        , test "All three scaling modes are valid; unknown modes block export" <|
            \_ ->
                List.map (\mode -> chosen |> step (Field "yard-mode" mode) |> validYardSettings) [ "fit", "fill", "stretch", "crop" ]
                    |> Expect.equal [ True, True, True, False ]
        , test "Unavailable detection can retry before file selection" <|
            \_ ->
                chosen |> step (ConnectorStatus chosen.connectorToken (Err Http.NetworkError)) |> View.view |> Query.fromHtml |> Query.has [ Selector.text "Retry detection" ]
        , test "Leaving and re-entering rejects the previous detection" <|
            \_ ->
                let
                    left =
                        step (ChooseTool Split) chosen

                    back =
                        step (ChooseTool YardSign) left |> step (ConnectorStatus chosen.connectorToken (Ok True))
                in
                Expect.equal ( NotChecked, Checking, Available ) ( left.connector, back.connector, (step (ConnectorStatus back.connectorToken (Ok True)) back).connector )
        , test "An invalid custom width clears the displayed proof and rejects the previous render" <|
            \_ ->
                let
                    initial =
                        { emptyYardProof | source = Just "source", token = 5, url = "previous" }

                    model =
                        { chosen | yardProof = initial, yardPreset = Nothing }

                    outdated =
                        BrowserEvent (E.object [ ( "action", E.string "yardPreview" ), ( "source", E.string "source" ), ( "token", E.int 5 ), ( "url", E.string "late" ) ])

                    changed =
                        model |> step (Field "yard-width" "") |> step outdated
                in
                Expect.equal ( False, "", 6 ) ( validYardSettings changed, changed.yardProof.url, changed.yardProof.token )
        , test "Session preparation from an abandoned proof cannot replace the current source" <|
            \_ ->
                let
                    current =
                        { emptyYardProof | session = 2, source = Just "new" }
                in
                { chosen | yardProof = current } |> step (YardSource 1 (Ok "old")) |> .yardProof |> Expect.equal current
        , test "A stale export failure does not interrupt a later operation" <|
            \_ ->
                step (YardExported (chosen.epoch - 1) Download "sign.pdf" (Err Http.Timeout)) chosen
                    |> .error
                    |> Expect.equal ""
        ]
