module State exposing (tests)

import Api.Generated as A
import Da.Dropdown as Dropdown
import Dict
import Expect
import Http
import Imposition as I
import Job
import Json.Decode as D
import Json.Encode as E
import Main
import Model exposing (..)
import RustWire
import Test exposing (..)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Validation as V
import View


initial : Model
initial =
    Tuple.first (Main.init "light")


step : Msg -> Model -> Model
step msg =
    Main.update msg >> Tuple.first


layout : Maybe A.LayoutResult
layout =
    RustWire.cases |> List.filter (\( name, _ ) -> name == "LayoutResult") |> List.head |> Maybe.andThen (Tuple.second >> D.decodeString A.layoutResultDecoder >> Result.toMaybe)


source : Maybe A.PreparedSourceResponse
source =
    RustWire.cases |> List.filter (\( name, _ ) -> name == "PreparedSourceResponse") |> List.head |> Maybe.andThen (Tuple.second >> D.decodeString A.preparedSourceResponseDecoder >> Result.toMaybe)


tests : Test
tests =
    describe "Validation and workspace transitions"
        [ test "Theme toggle preserves working inputs"
            (\_ ->
                let
                    before =
                        initial |> step (Field "finished-width" "3.5")

                    after =
                        step (Toggle "theme") before
                in
                Expect.equal ( ( False, "dark" ), before.request, before.drafts ) ( ( after.workspaceMenu, after.theme ), after.request, after.drafts )
            )
        , test "Workspace clear action opens confirmation before clearing settings"
            (\_ ->
                let
                    before =
                        initial |> step (Field "finished-width" "3.5") |> step (SetWorkspaceMenu True)

                    after =
                        step (WorkspaceAction "clear") before
                in
                Expect.equal ( ( False, "clear" ), before.request, before.drafts ) ( ( after.workspaceMenu, after.dialog ), after.request, after.drafts )
            )
        , test "Workspace clear cannot interrupt pending work"
            (\_ ->
                let
                    before =
                        { initial | busy = True, workspaceMenu = True }

                    after =
                        step (WorkspaceAction "clear") before
                in
                Expect.equal ( False, "", True ) ( after.workspaceMenu, after.dialog, after.busy )
            )
        , test "Dropdown navigation preserves geometry and pending layout until a value is committed"
            (\_ ->
                let
                    before =
                        initial |> step (Field "finished-width" "3.5") |> step (Field "finished-height" "2")

                    after =
                        step (DropdownChanged "finished-orientation" "landscape" { state = Dropdown.initial, value = "landscape" }) before
                in
                Expect.equal ( before.request, before.revision, before.drafts ) ( after.request, after.revision, after.drafts )
            )
        , test "Committing the orientation dropdown swaps the explicitly chosen dimensions"
            (\_ ->
                let
                    before =
                        initial |> step (Field "finished-width" "3.5") |> step (Field "finished-height" "2")

                    after =
                        step (DropdownChanged "finished-orientation" "landscape" { state = Dropdown.initial, value = "portrait" }) before
                in
                Expect.equal ( { width = 2, height = 3.5 }, True, True )
                    ( after.request.finishedCutSize, after.chosenWidth, after.chosenHeight )
            )
        , test "Changing sheet size through the dropdown retains finished sizing and fitting"
            (\_ ->
                let
                    before =
                        initial |> step (Field "finished-width" "5") |> step (Field "finished-height" "7") |> step (Field "fit" "cover")

                    after =
                        step (DropdownChanged "sheet" "12x18" { state = Dropdown.initial, value = "11x17" }) before
                in
                Expect.equal ( { width = 11, height = 17 }, before.request.finishedCutSize, before.request.artworkFit )
                    ( after.request.parentSheetSize, after.request.finishedCutSize, after.request.artworkFit )
            )
        , test "Closing presets clears transient dropdown state and retains layout settings"
            (\_ ->
                let
                    before =
                        initial |> step (Field "finished-width" "5") |> step (SetPresetsOpen True) |> step (DropdownChanged "apply-preset" "" { state = Dropdown.initial, value = "" })

                    after =
                        step (SetPresetsOpen False) before
                in
                Expect.equal ( ( False, True ), before.request, before.drafts )
                    ( ( after.presetsOpen, Dict.isEmpty after.dropdowns ), after.request, after.drafts )
            )
        , test "Setup navigation clears transient dropdown state and preserves inputs"
            (\_ ->
                let
                    before =
                        initial |> step (Field "finished-width" "3.5") |> step (DropdownChanged "finished-orientation" "landscape" { state = Dropdown.initial, value = "landscape" })

                    after =
                        step (SetStep 1) before
                in
                Expect.equal ( True, before.drafts, 1 ) ( Dict.isEmpty after.dropdowns, after.drafts, after.step )
            )
        , test "The three setup steps retain custom grid settings and invalid drafts"
            (\_ ->
                let
                    sheet =
                        initial
                            |> step (SetStep 1)
                            |> step (Field "layout" "manual")
                            |> step (Field "rows" "2")
                            |> step (Field "columns" "-")

                    back =
                        sheet |> step (SetStep 2) |> step (SetStep 0) |> step (SetStep 1)
                in
                Expect.equal ( sheet.request, sheet.drafts, 1 ) ( back.request, back.drafts, back.step )
            )
        , test "Bleed is the final setup step and navigation rejects removed steps"
            (\_ ->
                let
                    bleed =
                        step (SetStep 2) initial
                in
                Expect.all
                    [ \_ -> Expect.equal 2 bleed.step
                    , \_ -> Expect.equal bleed (step (SetStep 3) bleed)
                    , \_ -> Expect.equal bleed (step (SetStep -1) bleed)
                    ]
                    ()
            )
        , test "Storage failure keeps the chosen theme and reports that it was not saved"
            (\_ ->
                let
                    changed =
                        step (Toggle "theme") initial

                    failed =
                        step
                            (BrowserEvent
                                (E.object
                                    [ ( "action", E.string "themeStorageError" ) ]
                                )
                            )
                            changed
                in
                Expect.equal ( "dark", False, "" ) ( failed.theme, String.isEmpty failed.notice, failed.error )
            )
        , test "Malformed browser events preserve application state"
            (\_ ->
                Expect.equal initial (step (BrowserEvent E.null) initial)
            )
        , test "Dismissing an error toast retains the failed request and retry state"
            (\_ ->
                let
                    failed =
                        step (Catalog "presets" (Err Http.NetworkError)) initial

                    dismissed =
                        step (DismissToast 1) failed
                in
                Expect.equal ( Nothing, failed.error, "catalog:presets" ) ( dismissed.toast, dismissed.error, dismissed.retryKind )
            )
        , test "An old toast timer cannot dismiss a newer notification"
            (\_ ->
                let
                    confirmed =
                        step (Saved "recent-jobs" (Ok E.null)) initial

                    failed =
                        step (Catalog "presets" (Err Http.NetworkError)) confirmed
                in
                Expect.equal failed.toast (step (DismissToast 1) failed).toast
            )
        , test "Confirmation expiry removes its toast"
            (\_ ->
                step (Saved "recent-jobs" (Ok E.null)) initial
                    |> step (DismissToast 1)
                    |> .toast
                    |> Expect.equal Nothing
            )
        , test "Clearing the workspace preserves toast timer identity"
            (\_ ->
                let
                    confirmed =
                        step (Saved "recent-jobs" (Ok E.null)) initial

                    next =
                        confirmed |> step Clear |> step (Catalog "presets" (Err Http.NetworkError))
                in
                Expect.equal next.toast (step (DismissToast 1) next).toast
            )
        , test "Resolving a failed catalog request removes its error toast"
            (\_ ->
                initial
                    |> step (Catalog "presets" (Err Http.NetworkError))
                    |> step Retry
                    |> .toast
                    |> Expect.equal Nothing
            )
        , test "A valid preset can be saved at any step while the layout is pending"
            (\_ ->
                List.range 0 2
                    |> List.map
                        (\index ->
                            step (Save "presets") { initial | step = index, chosenWidth = True, chosenHeight = True, savedName = "21 business cards", layoutReady = False }
                                |> (\m -> ( m.error, m.retryKind ))
                        )
                    |> Expect.equal (List.repeat 3 ( "", "save:presets" ))
            )
        , test "Saving a preset rejects invalid settings and an empty name"
            (\_ ->
                [ { initial | chosenWidth = True, chosenHeight = True, savedName = "" }
                , { initial | chosenWidth = True, chosenHeight = True, savedName = "Invalid grid", drafts = Dict.singleton "invalid:rows" "bad" }
                ]
                    |> List.map (step (Save "presets") >> .error >> String.isEmpty)
                    |> Expect.equal [ False, False ]
            )
        , test "Rotating a page preserves shared size, quantities and other artwork overrides"
            (\_ ->
                let
                    r =
                        initial.request

                    before =
                        { initial | operation = Impose, request = { r | sourcePageCount = Just 2, pageOverrides = [ { pageNumber = 2, rotationDegrees = 0, finishedCutSize = Just { width = 3, height = 2 }, artworkFit = Nothing } ] } }

                    after =
                        step (RotateArtwork 2 90) before

                    restored =
                        step (RotateArtwork 2 0) after
                in
                Expect.all
                    [ \_ -> Expect.equal 0 (I.artworkRotation 1 after.request)
                    , \_ -> Expect.equal 90 (I.artworkRotation 2 after.request)
                    , \_ -> Expect.equal before.request restored.request
                    , \_ -> Expect.equal before.request.finishedCutSize after.request.finishedCutSize
                    , \_ -> Expect.equal before.request.quantityRequested after.request.quantityRequested
                    , \_ -> Expect.equal before (step (RotateArtwork 2 45) before)
                    , \_ -> Expect.equal before (step (RotateArtwork 3 90) before)
                    , \_ -> Expect.equal False after.layoutReady
                    ]
                    ()
            )
        , test "Artwork rotation applies to all 200 pages by default and retains piece settings"
            (\_ ->
                let
                    r =
                        initial.request

                    own =
                        { pageNumber = 2, rotationDegrees = 180, finishedCutSize = Just { width = 3, height = 2 }, artworkFit = Just { mode = A.ArtworkFitModeCover, position = { x = 0.2, y = 0.7 } } }

                    before =
                        { initial | operation = Impose, request = { r | sourcePageCount = Just 200, pageOverrides = [ own ] } }

                    after =
                        step (Field "artwork-rotation" "90") before

                    individual =
                        after |> step (Toggle "per-artwork") |> step (Field "page" "2") |> step (Field "artwork-rotation" "270")

                    reset =
                        individual |> step (Toggle "per-artwork") |> step (Field "artwork-rotation" "0")
                in
                Expect.all
                    [ \_ -> Expect.equal (List.repeat 200 90) (List.map .rotationDegrees after.request.pageOverrides)
                    , \_ -> Expect.equal (Just { own | rotationDegrees = 90 }) (List.filter (\p -> p.pageNumber == 2) after.request.pageOverrides |> List.head)
                    , \_ -> Expect.equal [ 90, 270, 90 ] (List.map (\page -> I.artworkRotation page individual.request) [ 1, 2, 200 ])
                    , \_ -> Expect.equal (List.repeat 200 0) (List.map .rotationDegrees reset.request.pageOverrides)
                    , \_ -> Expect.equal before.request.finishedCutSize after.request.finishedCutSize
                    , \_ -> Expect.equal before.request.quantityRequested after.request.quantityRequested
                    , \_ -> Expect.equal before.request.orientationPreference after.request.orientationPreference
                    , \_ -> Expect.equal False after.layoutReady
                    , \_ -> Expect.equal before (step (Field "artwork-rotation" "45") before)
                    , \_ -> Expect.equal { before | busy = True } (step (RotateAllArtwork 90) { before | busy = True })
                    ]
                    ()
            )
        , test "Finished size requires source preparation or entered dimensions"
            (\_ ->
                let
                    width =
                        step (Field "finished-width" "3.5") initial

                    both =
                        step (Field "finished-height" "2") width
                in
                Expect.equal [ False, True, False, True ] [ initial.chosenWidth, width.chosenWidth, width.chosenHeight, Main.validSetup both ]
            )
        , test "Prepared artwork initializes finished dimensions and refreshes untouched defaults"
            (\_ ->
                case source of
                    Nothing ->
                        Expect.fail "Missing Rust prepared-source contract"

                    Just prepared ->
                        let
                            analysis =
                                prepared.analysis

                            first =
                                step (Prepared 0 (Ok { prepared | analysis = { analysis | sourcePdfSize = { width = 5, height = 7 }, trimBox = Nothing, suggestedFinishedCutSize = Nothing } })) initial

                            replaced =
                                step (Prepared 0 (Ok prepared)) first
                        in
                        Expect.equal
                            ( ( { width = 5, height = 7 }, True ), ( I.detectedFinishedSize prepared.analysis, True ) )
                            ( ( first.request.finishedCutSize, Main.validSetup first ), ( replaced.request.finishedCutSize, Main.validSetup replaced ) )
            )
        , test "Finished defaults prefer the cut box, then detected cut, then full artwork"
            (\_ ->
                case source of
                    Nothing ->
                        Expect.fail "Missing Rust prepared-source contract"

                    Just prepared ->
                        let
                            analysis =
                                prepared.analysis

                            trim =
                                { left = 0.125, bottom = 0.125, right = 5.125, top = 7.125, width = 5, height = 7 }

                            inferred =
                                { analysis | sourcePdfSize = { width = 5.25, height = 7.25 }, trimBox = Nothing, suggestedFinishedCutSize = Just { width = 5, height = 7 }, sourcePages = [] }

                            withTrim =
                                { inferred | trimBox = Just trim, suggestedFinishedCutSize = Just { width = 4, height = 6 } }

                            full =
                                { inferred | suggestedFinishedCutSize = Nothing }

                            sizes =
                                List.map (\a -> (step (Prepared 0 (Ok { prepared | analysis = a })) initial).request.finishedCutSize) [ withTrim, inferred, full ]
                        in
                        Expect.equal [ { width = 5, height = 7 }, { width = 5, height = 7 }, { width = 5.25, height = 7.25 } ] sizes
            )
        , test "Images matching a common cut plus bleed retain their full 300 DPI size"
            (\_ ->
                case source of
                    Nothing ->
                        Expect.fail "Missing Rust prepared-source contract"

                    Just prepared ->
                        let
                            analysis =
                                prepared.analysis

                            size =
                                { width = 3.75, height = 2.25 }

                            image =
                                { sourcePdfSize = size, sourceTrimBox = Nothing, previewBox = Nothing, physicalSizeAssumed = True, filename = Just "card.png", originalPageNumber = Just 1 }

                            next =
                                step (Prepared 0 (Ok { prepared | analysis = { analysis | sourcePdfSize = size, trimBox = Nothing, suggestedFinishedCutSize = Just { width = 3.5, height = 2 }, sourcePages = [ image ] } })) initial
                        in
                        Expect.equal size next.request.finishedCutSize
            )
        , test "Preparing replacement artwork retains edited dimensions and invalid drafts"
            (\_ ->
                case source of
                    Nothing ->
                        Expect.fail "Missing Rust prepared-source contract"

                    Just prepared ->
                        let
                            edited =
                                step (Prepared 0 (Ok prepared)) initial |> step (Field "finished-width" "5") |> step (Field "finished-height" "7")

                            replaced =
                                step (Prepared 0 (Ok prepared)) edited

                            invalid =
                                edited |> step (Field "finished-width" "4.") |> step (Prepared 0 (Ok prepared))
                        in
                        Expect.equal
                            ( ( { width = 5, height = 7 }, False ), ( Just "4.", False ) )
                            ( ( replaced.request.finishedCutSize, replaced.autoFinishedSize ), ( Dict.get "finished-width" invalid.drafts, Main.validSetup invalid ) )
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
        , test "Enter in Copies for all applies the bulk quantity and prevents native submission"
            (\_ ->
                View.view { initial | dialog = "quantities" }
                    |> Query.fromHtml
                    |> Query.find [ Selector.id "bulk-copy-quantity" ]
                    |> Event.simulate (Event.custom "keydown" (E.object [ ( "key", E.string "Enter" ) ]))
                    |> (\event -> Expect.all [ Event.expect ApplyDialog, Event.expectPreventDefault ] event)
            )
        , test "Bulk copies replace stale individual drafts for simplex and duplex, including zero"
            (\_ ->
                let
                    apply sides count =
                        let
                            request =
                                initial.request

                            before =
                                { initial
                                    | dialog = "quantities"
                                    , bulkDraft = String.fromInt count
                                    , quantityDrafts = Dict.fromList [ ( 0, "8" ), ( 1, "-" ) ]
                                    , request = { request | sourcePageCount = Just 6, impositionMode = A.ImpositionModeRepeat, sides = sides }
                                }

                            after =
                                step ApplyDialog before
                        in
                        Expect.equal
                            ( Just
                                (List.repeat
                                    (if sides == A.SidesDouble then
                                        3

                                     else
                                        6
                                    )
                                    count
                                )
                            , ""
                            , Dict.empty
                            )
                            ( after.request.impressionQuantities, after.dialog, after.quantityDrafts )
                in
                Expect.all
                    [ \_ -> apply A.SidesSingle 3
                    , \_ -> apply A.SidesDouble 3
                    , \_ -> apply A.SidesSingle 0
                    , \_ -> apply A.SidesDouble 0
                    ]
                    ()
            )
        , test "Invalid bulk copies retain the dialog and current page quantities"
            (\_ ->
                let
                    check draft =
                        let
                            before =
                                { initial | dialog = "quantities", bulkDraft = draft }

                            after =
                                step ApplyDialog before
                        in
                        Expect.equal ( before.request, "quantities" ) ( after.request, after.dialog )
                in
                Expect.all (List.map (\draft -> \_ -> check draft) [ "", "-1", "1.5", "10001" ]) ()
            )
        , test "Preset application retains artwork identity, overrides and quantities"
            (\_ ->
                let
                    r =
                        I.initial

                    request =
                        { r | sourceId = Just "source-7", sourcePageCount = Just 3, impositionMode = A.ImpositionModeRepeat, impressionQuantities = Just [ 2, 0, 3 ], quantityRequested = 5, pageOverrides = [ { pageNumber = 2, rotationDegrees = 0, finishedCutSize = Just { width = 2, height = 1 }, artworkFit = Nothing } ] }

                    p =
                        { id = "preset", name = "Test", impositionMode = A.ImpositionModeUnique, finishedSizeMode = A.FinishedSizeModeCommon, artworkFit = r.artworkFit, sourceBleedOverride = Nothing, finishedCutSize = { width = 4.25, height = 6.25 }, parentSheetSize = r.parentSheetSize, bleedHandling = r.bleedOption, createdBleedAmount = r.createdBleedAmount, gutter = r.gutter, orientationPreference = r.orientationPreference, sides = r.sides, layoutPreference = r.layoutMode, manual = r.manual, duplex = r.duplex, outputPreference = A.OutputPreferenceCleanPdf, builtIn = False }

                    next =
                        I.applyPreset p request
                in
                Expect.equal ( request.sourceId, request.impressionQuantities, request.pageOverrides ) ( next.sourceId, next.impressionQuantities, next.pageOverrides )
            )
        , test "Selecting repeat opens quantities in Sheet without advancing and reopening retains copies"
            (\_ ->
                let
                    r =
                        I.initial

                    before =
                        { initial | step = 1, request = { r | sourcePageCount = Just 2 } }

                    opened =
                        step (Field "mode" "repeat") before

                    edited =
                        opened |> step (Quantity 0 "7") |> step CloseDialog

                    reopened =
                        edited |> step (Field "mode" "unique") |> step (Field "mode" "repeat")
                in
                Expect.equal ( ( 1, "quantities", Just [ 1, 1 ] ), ( 1, "quantities", Just [ 7, 1 ] ) )
                    ( ( opened.step, opened.dialog, opened.request.impressionQuantities ), ( reopened.step, reopened.dialog, reopened.request.impressionQuantities ) )
            )
        , test "Repeat opens quantities for a single page and for duplex pairs"
            (\_ ->
                let
                    r =
                        I.initial

                    single =
                        step (Field "mode" "repeat") { initial | request = { r | sourcePageCount = Just 1 } }

                    duplex =
                        { initial | request = { r | sourcePageCount = Just 4 } }
                            |> step (Field "sides" "double")
                            |> step (Field "mode" "repeat")
                in
                Expect.equal ( ( "quantities", [ 1 ] ), ( "quantities", [ 1, 1 ] ) )
                    ( ( single.dialog, I.quantities single.request ), ( duplex.dialog, I.quantities duplex.request ) )
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
        , test "A duplex preset selected from the dropdown retains simplex quantities and printing choices"
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
                                step (DropdownChanged "apply-preset" "" { state = Dropdown.initial, value = p.id }) working

                            restored =
                                step (Field "sides" "single") applied
                        in
                        Expect.equal ( ( A.SidesDouble, Just "retained-source", Just [ 2, 0, 4, 1 ] ), working.dialog )
                            ( ( applied.request.sides, applied.request.sourceId, restored.request.impressionQuantities ), applied.dialog )
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
