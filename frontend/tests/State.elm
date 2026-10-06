module State exposing (tests)

import Api.Generated as A
import Dict
import Expect
import Imposition as I
import Job
import Json.Decode as D
import Json.Encode as E
import Main
import Model exposing (..)
import RustWire
import Test exposing (..)
import Validation as V


initial : Model
initial =
    Tuple.first (Main.init "light")


step : Msg -> Model -> Model
step msg =
    Main.update msg >> Tuple.first


layout : Maybe A.LayoutResult
layout =
    RustWire.cases |> List.filter (\( name, _ ) -> name == "LayoutResult") |> List.head |> Maybe.andThen (Tuple.second >> D.decodeString A.layoutResultDecoder >> Result.toMaybe)


tests : Test
tests =
    describe "Validation and workspace transitions"
        [ test "Explicit finished choices are required even when the displayed defaults match"
            (\_ ->
                let
                    width =
                        step (Field "finished-width" "3.5") initial

                    both =
                        step (Field "finished-height" "2") width
                in
                Expect.equal [ False, True, False, True ] [ initial.chosenWidth, width.chosenWidth, width.chosenHeight, Main.validSetup both ]
            )
        , test "Decimal drafts keep 4. intact and recover as 4.25"
            (\_ ->
                let
                    partial =
                        step (Field "finished-width" "4.") initial

                    complete =
                        step (Field "finished-width" "4.25") partial
                in
                Expect.equal ( ( Just "4.", False ), ( 4.25, False ) ) ( ( Dict.get "finished-width" partial.drafts, Main.validSetup partial ), ( complete.request.finishedCutSize.width, Dict.member "invalid:finished-width" complete.drafts ) )
            )
        , test "Crop anchors include both exact endpoints"
            (\_ ->
                let
                    first =
                        step (Field "crop-x" "0") initial

                    last =
                        step (Field "crop-x" "1") first
                in
                Expect.equal ( Just 0, Just 1 ) ( Maybe.map (.position >> .x) first.request.artworkFit, Maybe.map (.position >> .x) last.request.artworkFit )
            )
        , test "Cancellation advances identity and retains settings"
            (\_ ->
                let
                    working =
                        { initial | busy = True, epoch = 9, revision = 4, previewToken = 7, request = I.setMode A.ImpositionModeRepeat I.initial }

                    cancelled =
                        step Cancel working
                in
                Expect.equal ( ( 10, False ), ( working.request, 8 ) ) ( ( cancelled.epoch, cancelled.busy ), ( cancelled.request, cancelled.previewToken ) )
            )
        , test "Late inspection and job results cannot re-enter a cancelled workflow"
            (\_ ->
                let
                    cancelled =
                        step Cancel { initial | epoch = 9, busy = True }

                    late =
                        step (Inspected 9 1 (Ok 30)) cancelled |> step (Created 9 "prepare" (Ok "obsolete-job"))
                in
                Expect.equal ( cancelled.files, False, Nothing ) ( late.files, late.busy, late.job )
            )
        , test "Old layout revision cannot publish its response"
            (\_ ->
                case layout of
                    Nothing ->
                        Expect.fail "Missing Rust layout contract"

                    Just l ->
                        let
                            current =
                                { initial | operation = Impose, revision = 8 }

                            late =
                                step (LaidOut 7 (Ok l)) current
                        in
                        Expect.equal ( Nothing, False ) ( late.layout, late.layoutReady )
            )
        , test "Superseded preview URLs cannot replace the display"
            (\_ ->
                let
                    current =
                        { initial | operation = Impose, previewToken = 8, previewLoading = True }

                    late =
                        step (BrowserEvent (E.object [ ( "action", E.string "preview" ), ( "token", E.int 7 ), ( "urls", E.list identity [] ) ])) current
                in
                Expect.equal ( Nothing, True ) ( late.display, late.previewLoading )
            )
        , test "Page selection deduplicates and follows source order" (\_ -> Expect.equal (Ok [ 1, 2, 3, 5 ]) (V.pages 5 "5, 1-3, 2"))
        , test "Page validation rejects reversed ranges, empty parts, zero and bounds"
            (\_ ->
                List.map (V.pages 5 >> Result.toMaybe) [ "3-1", "1,", "0", "6", "1.5" ] |> Expect.equal (List.repeat 5 Nothing)
            )
        , test "Numeric validation rejects partial, negative and fractional quantities"
            (\_ ->
                Expect.equal ( Nothing, Nothing, Nothing ) ( Result.toMaybe (V.number 0.01 100 "4."), Result.toMaybe (V.whole 0 10000 "-1"), Result.toMaybe (V.whole 0 10000 "2.5") )
            )
        , test "Preset application retains artwork identity, overrides and quantities"
            (\_ ->
                let
                    r =
                        I.initial

                    request =
                        { r | sourceId = Just "source-7", sourcePageCount = Just 3, impositionMode = A.ImpositionModeRepeat, impressionQuantities = Just [ 2, 0, 3 ], quantityRequested = 5, pageOverrides = [ { pageNumber = 2, finishedCutSize = Just { width = 2, height = 1 }, artworkFit = Nothing } ] }

                    p =
                        { id = "preset", name = "Test", impositionMode = A.ImpositionModeUnique, finishedSizeMode = A.FinishedSizeModeCommon, artworkFit = r.artworkFit, sourceBleedOverride = Nothing, finishedCutSize = { width = 4.25, height = 6.25 }, parentSheetSize = r.parentSheetSize, bleedHandling = r.bleedOption, createdBleedAmount = r.createdBleedAmount, gutter = r.gutter, orientationPreference = r.orientationPreference, sides = r.sides, layoutPreference = r.layoutMode, manual = r.manual, duplex = r.duplex, outputPreference = A.OutputPreferenceCleanPdf, builtIn = False }

                    next =
                        I.applyPreset p request
                in
                Expect.equal ( request.sourceId, request.impressionQuantities, request.pageOverrides ) ( next.sourceId, next.impressionQuantities, next.pageOverrides )
            )
        , test "Simplex and duplex quantity drafts survive mode changes"
            (\_ ->
                let
                    r =
                        I.initial

                    working =
                        { initial | request = { r | sourcePageCount = Just 4, impositionMode = A.ImpositionModeRepeat, impressionQuantities = Just [ 2, 0, 4, 1 ], quantityRequested = 7 } }

                    duplex =
                        step (Field "sides" "double") working

                    changed =
                        step (Quantity 0 "3") duplex

                    simplex =
                        step (Field "sides" "single") changed

                    again =
                        step (Field "sides" "double") simplex
                in
                Expect.equal ( Just [ 2, 0, 4, 1 ], Just [ 3, 1 ] ) ( simplex.request.impressionQuantities, again.request.impressionQuantities )
            )
        , test "Setup dimensions stay shared while a selected artwork override is enabled"
            (\_ ->
                let
                    own =
                        step (Field "artwork-width" "2") { initial | perArtwork = True, selectedPage = 2 }

                    shared =
                        step (Field "finished-width" "5") own
                in
                Expect.equal ( 5, Just { width = 2, height = 2 } ) ( shared.request.finishedCutSize.width, List.head shared.request.pageOverrides |> Maybe.andThen .finishedCutSize )
            )
        , test "An invalid quantity rejects an outstanding layout response"
            (\_ ->
                case layout of
                    Nothing ->
                        Expect.fail "Missing Rust layout fixture"

                    Just l ->
                        let
                            current =
                                { initial | operation = Impose, revision = 4 }

                            invalid =
                                step (Quantity 0 "-") current

                            late =
                                step (LaidOut 4 (Ok l)) invalid
                        in
                        Expect.equal ( Nothing, False ) ( late.layout, late.layoutReady )
            )
        , test "Text job parser preserves equals inside filenames and error details"
            (\_ ->
                let
                    job =
                        Job.parse "status=done\npercent=100\nstage=Ready\nfilename=a=b.pdf\nerror=a=b"
                in
                Expect.equal ( ( "done", 100 ), ( "a=b.pdf", "a=b" ) ) ( ( job.state, job.percent ), ( job.filename, job.error ) )
            )
        , test "Selecting an artwork scope cannot clear an invalid shared dimension"
            (\_ ->
                let
                    invalid =
                        step (Field "finished-width" "4.") initial

                    changed =
                        step (Toggle "per-artwork") invalid |> step (Field "page" "2")
                in
                Expect.equal ( Just "4.", False ) ( Dict.get "finished-width" changed.drafts, Main.validSetup changed )
            )
        , test "Late browser download errors cannot disturb a newer operation"
            (\_ ->
                let
                    working =
                        { initial | epoch = 5, busy = True }

                    late =
                        step (BrowserEvent (E.object [ ( "action", E.string "downloadError" ), ( "token", E.int 4 ), ( "message", E.string "old failure" ) ])) working
                in
                Expect.equal ( True, "" ) ( late.busy, late.error )
            )
        , test "A duplex preset restores printing choices while retaining simplex quantities"
            (\_ ->
                case RustWire.cases |> List.filter (\( name, _ ) -> name == "GangUpPreset") |> List.head |> Maybe.andThen (Tuple.second >> D.decodeString A.gangUpPresetDecoder >> Result.toMaybe) of
                    Nothing ->
                        Expect.fail "Missing production preset fixture"

                    Just p ->
                        let
                            r =
                                I.initial

                            working =
                                { initial | presets = [ p ], request = { r | sourceId = Just "retained-source", sourcePageCount = Just 4, impositionMode = A.ImpositionModeRepeat, impressionQuantities = Just [ 2, 0, 4, 1 ], quantityRequested = 7 } }

                            applied =
                                step (ApplyPreset p.id) working

                            restored =
                                step (Field "sides" "single") applied
                        in
                        Expect.equal ( A.SidesDouble, Just "retained-source", Just [ 2, 0, 4, 1 ] ) ( applied.request.sides, applied.request.sourceId, restored.request.impressionQuantities )
            )
        , test "Duplex preview pages use ordered pairs and stop at empty positions"
            (\_ ->
                case layout of
                    Nothing ->
                        Expect.fail "Missing layout fixture"

                    Just l ->
                        Expect.equal ( Just 1, Just 2, Nothing ) ( I.pageNumber l 0 False 0, I.pageNumber l 0 True 0, I.pageNumber l 0 False 3 )
            )
        ]
