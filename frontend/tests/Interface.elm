module Interface exposing (tests)

import Api.Generated as A
import Expect
import Json.Decode as D
import Main
import Model exposing (..)
import OutputSummary
import Preview
import RustWire
import Test exposing (..)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import View


initial : Model
initial =
    Main.init "light" |> Tuple.first


step : Msg -> Model -> Model
step msg =
    Main.update msg >> Tuple.first


tests : Test
tests =
    describe "Task discovery and preview inspection"
        [ test "Every task is discoverable before upload without requiring a choice"
            (\_ ->
                View.view initial
                    |> Query.fromHtml
                    |> Query.findAll [ Selector.class "home-tool-choice" ]
                    |> Query.count (Expect.equal 5)
            )
        , test "Choosing a tool preserves intent for intake"
            (\_ ->
                let
                    chosen =
                        step (ChooseTool Split) initial
                in
                Expect.equal ( Split, Just Split ) ( chosen.operation, chosen.preferredTool )
            )
        , test "Task choice is blocked during an upload"
            (\_ ->
                let
                    busy =
                        { initial | busy = True }

                    chosen =
                        step (ChooseTool Impose) busy
                in
                Expect.equal ( PdfImage, Nothing ) ( chosen.operation, chosen.preferredTool )
            )
        , test "Clearing starts a fresh task choice and preview"
            (\_ ->
                let
                    cleared =
                        initial |> step (ChooseTool Impose) |> step (SetPreviewZoom 300) |> step TogglePreviewGuides |> step Clear
                in
                Expect.equal ( Nothing, 100, True ) ( cleared.preferredTool, cleared.previewZoom, cleared.previewGuides )
            )
        , test "Zoom is bounded and fitting restores the whole sheet"
            (\_ ->
                Expect.equal [ 100, 300, 100 ]
                    [ (step (SetPreviewZoom 10) initial).previewZoom
                    , (step (SetPreviewZoom 500) initial).previewZoom
                    , (initial |> step (SetPreviewZoom 200) |> step FitPreview).previewZoom
                    ]
            )
        , test "Inspection does not change print settings, selection or request identities"
            (\_ ->
                let
                    before =
                        { initial | selectedImpression = Just 2 }

                    after =
                        before |> step (SetPreviewZoom 200) |> step TogglePreviewGuides
                in
                Expect.all
                    [ \_ -> Expect.equal before.request after.request
                    , \_ -> Expect.equal ( before.revision, before.previewToken, before.selectedImpression ) ( after.revision, after.previewToken, after.selectedImpression )
                    , \_ -> Expect.equal False after.previewGuides
                    ]
                    ()
            )
        , test "Choosing another task clears an incompatible intake error"
            (\_ ->
                let
                    before =
                        { initial | error = "Choose PDF files for this tool." }
                in
                Expect.equal "" (step (ChooseTool ImagePdf) before).error
            )
        , test "Inspection actions are unavailable until a preview exists"
            (\_ ->
                Preview.view initial
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "preview-zoom-in" ]
                    |> Query.has [ Selector.disabled True ]
            )
        , test "Review navigation preserves print settings and returns from preview to setup"
            (\_ ->
                let
                    before =
                        { initial | operation = Impose, rail = "preview", step = 0 }

                    after =
                        step (SetStep 2) before
                in
                Expect.all
                    [ \_ -> Expect.equal ( 2, "setup" ) ( after.step, after.rail )
                    , \_ -> Expect.equal before.request after.request
                    , \_ -> Expect.equal ( before.revision, before.previewToken ) ( after.revision, after.previewToken )
                    ]
                    ()
            )
        , test "Workspace tabs accept only known panels without changing layout state"
            (\_ ->
                let
                    preview =
                        step (SetRail "preview") initial

                    rejected =
                        step (SetRail "unknown") preview
                in
                Expect.equal ( "preview", initial.request, initial.revision ) ( rejected.rail, rejected.request, rejected.revision )
            )
        , test "Output summary never presents an old layout as ready"
            (\_ ->
                let
                    layout =
                        RustWire.cases |> List.filter (\( name, _ ) -> name == "LayoutResult") |> List.head |> Maybe.andThen (Tuple.second >> D.decodeString A.layoutResultDecoder >> Result.toMaybe)

                    pending =
                        { initial | layout = layout, layoutReady = False }
                in
                Expect.equal "Updating print layout… Download is available when the layout is ready." (OutputSummary.imposed pending)
            )
        ]
