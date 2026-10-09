module View exposing (view)

import Api.Generated as A
import Dict
import File
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Keyed as Keyed
import Imposition as I
import Json.Decode as D
import Model exposing (..)
import Preview
import Svg
import Svg.Attributes as SA
import Validation as V


btn : String -> Msg -> Html Msg
btn title message =
    button [ type_ "button", class "ghost-button", onClick message ] [ text title ]


primary : String -> Msg -> Bool -> Html Msg
primary title message blocked =
    button [ type_ "button", class "primary-button", onClick message, disabled blocked ] [ text title ]


choices : String -> String -> String -> List ( String, String ) -> Html Msg
choices title key selected options =
    div [ class "field" ]
        [ span [] [ text title ]
        , div [ class "segmented-control", attribute "role" "group", attribute "aria-label" title ]
            (List.map
                (\( v, t ) ->
                    button
                        [ type_ "button"
                        , attribute "aria-pressed"
                            (if v == selected then
                                "true"

                             else
                                "false"
                            )
                        , onClick (Field key v)
                        ]
                        [ text t ]
                )
                options
            )
        ]


selectField : String -> String -> String -> List ( String, String ) -> Html Msg
selectField title key selected options =
    label [ class "field" ] [ span [] [ text title ], select [ attribute "aria-label" title, value selected, onInput (Field key) ] (List.map (\( v, t ) -> option [ value v, Html.Attributes.selected (v == selected) ] [ text t ]) options) ]


check : String -> String -> Bool -> Html Msg
check title key state =
    label [ class "field checkbox-field" ] [ input [ type_ "checkbox", checked state, onCheck (\_ -> Toggle key) ] [], span [] [ text title ] ]


numberField : Model -> String -> String -> Float -> Html Msg
numberField m title key n =
    let
        invalid =
            Dict.get ("invalid:" ++ key) m.drafts
    in
    label [ class "field" ]
        [ span [] [ text title ]
        , input
            [ id key
            , attribute "aria-label" title
            , type_ "text"
            , attribute "inputmode" "decimal"
            , value
                (Dict.get key m.drafts
                    |> Maybe.withDefault
                        (if (key == "finished-width" && not m.chosenWidth) || (key == "finished-height" && not m.chosenHeight) then
                            ""

                         else
                            String.fromFloat n
                        )
                )
            , onInput (Field key)
            , attribute "aria-invalid"
                (if invalid /= Nothing then
                    "true"

                 else
                    "false"
                )
            ]
            []
        , small [ class "field-error" ] [ text (Maybe.withDefault "" invalid) ]
        ]


view : Model -> Html Msg
view m =
    main_ [ classList [ ( "shell", True ), ( "elm-shell", True ), ( "empty-shell", List.isEmpty m.files ), ( "generic-shell", m.operation /= Impose ) ], preventDefaultOn "dragover" (D.succeed ( NoOp, True )), on "elm-files" (D.map Dropped (D.field "detail" (D.list File.decoder))) ]
        [ if List.isEmpty m.files then
            text ""

          else
            headerView m
        , if List.isEmpty m.files then
            emptyView m

          else
            section [ classList [ ( "ready-shell", True ), ( "generic-ready", m.operation /= Impose ) ] ]
                [ section [ classList [ ( "ready-card", True ), ( "imposing", m.operation == Impose ) ] ]
                    [ nav [ class "operation-chooser", attribute "aria-label" "PDF tools" ]
                        (List.map
                            (\op ->
                                button
                                    [ type_ "button"
                                    , attribute "aria-pressed"
                                        (if m.operation == op then
                                            "true"

                                         else
                                            "false"
                                        )
                                    , disabled m.busy
                                    , onClick (Switch op)
                                    ]
                                    [ text (Model.operationLabel op) ]
                            )
                            (operations m.files)
                        )
                    , if m.operation == Impose then
                        imposeView m

                      else
                        genericView m
                    ]
                ]
        , if m.dialog == "" then
            text ""

          else
            dialogView m
        ]


headerView : Model -> Html Msg
headerView m =
    header [ class "app-header" ]
        [ div [ class "app-brand" ] [ strong [] [ text "PDF Tools" ] ]
        , div [ class "app-file-context" ]
            [ span [] [ text "Current file" ]
            , strong [ title (List.map (.file >> File.name) m.files |> String.join ", ") ]
                [ text
                    (if List.length m.files == 1 then
                        List.head m.files |> Maybe.map (.file >> File.name) |> Maybe.withDefault ""

                     else
                        String.fromInt (List.length m.files) ++ " files"
                    )
                ]
            , small [] [ text (String.fromInt (List.sum (List.map (.file >> File.size) m.files) // 1024) ++ " KB") ]
            ]
        , div [ class "app-header-actions" ]
            [ button
                [ class "ghost-button"
                , disabled m.busy
                , onClick (Browse True)
                , attribute "aria-label"
                    (if m.operation == Impose then
                        "Add artwork"

                     else
                        "Add files"
                    )
                ]
                [ span [ class "button-label-wide" ]
                    [ text
                        (if m.operation == Impose then
                            "Add artwork"

                         else
                            "Add files"
                        )
                    ]
                , span [ class "button-label-short", attribute "aria-hidden" "true" ] [ text "Add" ]
                ]
            , button
                [ class "ghost-button"
                , disabled m.busy
                , onClick (Browse False)
                , attribute "aria-label"
                    (if m.operation == Impose then
                        "Replace artwork"

                     else
                        "Replace files"
                    )
                ]
                [ span [ class "button-label-wide" ]
                    [ text
                        (if m.operation == Impose then
                            "Replace artwork"

                         else
                            "Replace files"
                        )
                    ]
                , span [ class "button-label-short", attribute "aria-hidden" "true" ] [ text "Replace" ]
                ]
            , button [ id "clear-workspace-trigger", class "clear-workspace-button", disabled m.busy, onClick (OpenDialog "clear") ] [ text "Clear" ]
            , themeToggle m
            ]
        ]


themeToggle : Model -> Html Msg
themeToggle m =
    button
        [ type_ "button"
        , class "theme-toggle"
        , attribute "role" "switch"
        , attribute "aria-label" "Dark mode"
        , attribute "aria-checked"
            (if m.theme == "dark" then
                "true"

             else
                "false"
            )
        , title
            (if m.theme == "dark" then
                "Switch to light mode"

             else
                "Switch to dark mode"
            )
        , onClick (Toggle "theme")
        ]
        [ Svg.svg
            [ SA.class "ui-icon theme-toggle-icon"
            , SA.viewBox "0 0 24 24"
            , SA.width "20"
            , SA.height "20"
            , SA.fill "none"
            , SA.stroke "currentColor"
            , attribute "aria-hidden" "true"
            ]
            (if m.theme == "dark" then
                [ Svg.path [ SA.d "M20.9 13.3A9 9 0 0 1 10.7 3.1 9 9 0 1 0 20.9 13.3Z" ] [] ]

             else
                [ Svg.circle [ SA.cx "12", SA.cy "12", SA.r "4" ] []
                , Svg.path [ SA.d "M12 2v2m0 16v2M2 12h2m16 0h2M4.93 4.93l1.42 1.42m11.3 11.3 1.42 1.42M4.93 19.07l1.42-1.42m11.3-11.3 1.42-1.42" ] []
                ]
            )
        ]


statusView : Model -> Html Msg
statusView m =
    div [ class "elm-status" ]
        [ if m.busy then
            div [ class "progress-status", attribute "role" "status" ]
                [ div [] [ span [] [ text m.phase ], strong [] [ text (String.fromInt m.progress ++ "%") ] ]
                , progress [ value (String.fromInt m.progress), Html.Attributes.max "100" ] []
                , btn
                    (if m.phase == "Checking PDFs" then
                        "Cancel inspection"

                     else
                        "Cancel"
                    )
                    Cancel
                ]

          else
            text ""
        , if m.error /= "" then
            div [ class "error", attribute "role" "alert" ] [ p [] [ text m.error ], btn "Retry" Retry ]

          else
            text ""
        , if m.notice /= "" then
            div [ class "export-notice", attribute "role" "status" ]
                [ text m.notice
                , if String.startsWith "Cancelled" m.notice then
                    btn "Retry" Retry

                  else
                    text ""
                ]

          else
            text ""
        ]


emptyView : Model -> Html Msg
emptyView m =
    section [ class "empty-state" ] [ themeToggle m, div [ class "empty-state-content" ] [ div [ class "empty-intro" ] [ p [ class "eyebrow" ] [ text "PDF Tools" ], h1 [] [ text "Upload files" ] ], button [ id "browse-files", class "primary-button", disabled m.busy, onClick (Browse False) ] [ text "Browse files" ], p [ id "empty-state-description" ] [ text "PDF, PNG, or JPEG. Drop files here to begin." ], statusView m ] ]


queueView : Model -> Html Msg
queueView m =
    section [ class "file-queue", attribute "aria-label" "Selected files" ]
        [ div [ class "file-queue-head" ] [ h2 [] [ text "Files" ], small [] [ text "Drag or use the arrow buttons to reorder." ] ]
        , Keyed.node "div"
            [ class "file-list" ]
            (List.indexedMap
                (\i f ->
                    ( String.fromInt f.id
                    , div
                        [ id ("file-row-" ++ String.fromInt f.id)
                        , tabindex 0
                        , class "file-row"
                        , draggable "true"
                        , on "dragstart" (D.succeed (Drag f.id))
                        , preventDefaultOn "dragover" (D.succeed ( NoOp, True ))
                        , stopPropagationOn "drop" (D.succeed ( DropOn f.id, True ))
                        , preventDefaultOn "keydown"
                            (D.map2
                                (\key alt ->
                                    if alt && List.member key [ "ArrowUp", "ArrowDown" ] then
                                        ( Move f.id
                                            (if key == "ArrowUp" then
                                                -1

                                             else
                                                1
                                            )
                                        , True
                                        )

                                    else
                                        ( NoOp, False )
                                )
                                (D.field "key" D.string)
                                (D.field "altKey" D.bool)
                            )
                        ]
                        [ span [ class "file-order" ] [ text (String.fromInt (i + 1)) ]
                        , div [ class "file-meta" ]
                            [ span [ title (File.name f.file) ] [ text (File.name f.file) ]
                            , small []
                                [ text
                                    (if isPdf f.file then
                                        String.fromInt f.pages ++ " pages"

                                     else
                                        "300 DPI"
                                    )
                                ]
                            ]
                        , div [ class "file-row-actions" ]
                            [ button [ type_ "button", class "icon-button", disabled (m.busy || i == 0), attribute "aria-label" ("Move " ++ File.name f.file ++ " up"), onClick (Move f.id -1) ] [ text "↑" ]
                            , button [ type_ "button", class "icon-button", disabled (m.busy || i == List.length m.files - 1), attribute "aria-label" ("Move " ++ File.name f.file ++ " down"), onClick (Move f.id 1) ] [ text "↓" ]
                            , button [ type_ "button", class "icon-button remove-file", disabled m.busy, attribute "aria-label" ("Remove " ++ File.name f.file), onClick (Remove f.id) ] [ text "×" ]
                            ]
                        ]
                    )
                )
                m.files
            )
        ]


pageChoices : Model -> Html Msg
pageChoices m =
    let
        current =
            if m.operation == Split then
                m.extractPages

            else
                m.imagePages
    in
    div [ class "page-selection" ]
        [ div [ class "field" ]
            [ span [] [ text "Pages" ]
            , div [ class "segmented-control" ]
                [ button
                    [ type_ "button"
                    , attribute "aria-pressed"
                        (if current == "all" then
                            "true"

                         else
                            "false"
                        )
                    , onClick (Field "pages" "all")
                    ]
                    [ text "All pages" ]
                , button
                    [ id "range-trigger"
                    , type_ "button"
                    , attribute "aria-haspopup" "dialog"
                    , attribute "aria-pressed"
                        (if current /= "all" then
                            "true"

                         else
                            "false"
                        )
                    , onClick (OpenDialog "range")
                    ]
                    [ text "Page range" ]
                ]
            , if current /= "all" then
                small [] [ text current ]

              else
                text ""
            ]
        ]


genericView : Model -> Html Msg
genericView m =
    let
        current =
            if m.operation == Split then
                m.extractPages

            else
                m.imagePages

        validPages =
            not (List.member m.operation [ PdfImage, Split ]) || current == "all" || Result.toMaybe (V.pages (List.sum (List.map .pages m.files)) current) /= Nothing

        validChunk =
            m.operation /= Split || m.outputMode /= "chunks" || Result.toMaybe (V.whole 1 1000 m.chunk) /= Nothing

        fields =
            case m.operation of
                PdfImage ->
                    [ pageChoices m
                    , choices "Image format" "target" m.target [ ( "png", "PNG" ), ( "jpeg", "JPEG" ) ]
                    , choices "Quality" "quality" m.quality [ ( "screen", "Screen" ), ( "print", "Standard" ), ( "high", "High" ) ]
                    , small [ class "field-help" ]
                        [ text
                            (case m.quality of
                                "print" ->
                                    "300 DPI · print quality"

                                "high" ->
                                    "600 DPI · high quality"

                                _ ->
                                    "144 DPI · screen quality"
                            )
                        ]
                    ]

                Split ->
                    [ pageChoices m
                    , choices "Output" "output" m.outputMode [ ( "individual", "Individual" ), ( "combined", "Combined" ), ( "chunks", "Chunks" ) ]
                    , if m.outputMode == "chunks" then
                        label [ class "field" ]
                            [ span [] [ text "Pages per chunk" ]
                            , input [ id "extract-chunk-size", type_ "text", attribute "inputmode" "numeric", value m.chunk, onInput (Field "chunk") ] []
                            , if validChunk then
                                small [] [ text "Consecutive groups of selected pages." ]

                              else
                                small [ class "field-error", attribute "role" "alert" ] [ text "Enter a whole number from 1 to 1000." ]
                            ]

                      else
                        text ""
                    ]

                ImagePdf ->
                    [ p [ class "field-help" ] [ text "Each page matches its image at 300 DPI. One image per page." ] ]

                _ ->
                    [ p [ class "field-help" ] [ text "Put PDFs in order and combine them into one file." ] ]

        action =
            case m.operation of
                PdfImage ->
                    "Download images"

                Split ->
                    if m.outputMode == "combined" then
                        "Download PDF"

                    else
                        "Download ZIP"

                ImagePdf ->
                    "Create PDF"

                _ ->
                    "Download PDF"
    in
    div [ class "workspace-grid ordered-files" ] [ queueView m, Html.form [ class "tool-form", onSubmit Submit ] [ div [ class "tool-form-head" ] [ h2 [ id "operation-settings-heading" ] [ text (Model.operationLabel m.operation) ] ], fieldset [ class "tool-form-fields", disabled m.busy ] fields, div [ class "submit-row" ] [ primary action Submit (m.busy || not validPages || not validChunk), statusView m ] ] ]


setupValid : Model -> Bool
setupValid m =
    m.chosenWidth && m.chosenHeight && m.request.quantityRequested > 0 && m.request.quantityRequested <= 10000 && Dict.isEmpty (Dict.filter (\k _ -> String.startsWith "invalid:" k) m.drafts) && Dict.isEmpty (Dict.filter (\_ v -> Result.toMaybe (V.whole 0 10000 v) == Nothing) m.quantityDrafts)


imposeView : Model -> Html Msg
imposeView m =
    section
        [ classList [ ( "gang-workspace embedded compact has-layout", True ), ( "elm-impose-busy", m.busy ) ]
        , attribute "data-layout-state"
            (if not (setupValid m) then
                "invalid"

             else if m.layoutReady then
                "ready"

             else if m.error /= "" then
                "error"

             else
                "pending"
            )
        ]
        [ statusView m
        , if m.source == Nothing then
            div [ class "impose-preparation-region" ]
                [ p [] [ text "Prepare your selected artwork to open the sheet." ]
                , if not m.busy then
                    primary "Retry preparation" Retry False

                  else
                    text ""
                ]

          else
            div [ classList [ ( "gang-grid", True ), ( "elm-impose-grid", True ), ( "elm-collapsed", m.collapsed ), ( "elm-preview-active", m.rail == "preview" ) ] ]
                [ div [ class "gang-rail-switcher", attribute "role" "tablist", attribute "aria-label" "Imposition workspace sections" ]
                    [ button
                        [ id "gang-setup-tab"
                        , attribute "role" "tab"
                        , attribute "aria-selected"
                            (if m.rail /= "preview" then
                                "true"

                             else
                                "false"
                            )
                        , onClick (SetRail "setup")
                        ]
                        [ text "Setup" ]
                    , button
                        [ id "gang-preview-tab"
                        , attribute "role" "tab"
                        , attribute "aria-selected"
                            (if m.rail == "preview" then
                                "true"

                             else
                                "false"
                            )
                        , onClick (SetRail "preview")
                        ]
                        [ text "Preview" ]
                    ]
                , setupView m
                , toolbarView m
                , Preview.view m
                ]
        ]


setupTabKey : Int -> D.Decoder ( Msg, Bool )
setupTabKey index =
    D.field "key" D.string
        |> D.andThen
            (\key ->
                case key of
                    "ArrowRight" ->
                        D.succeed ( SetStep (modBy 4 (index + 1)), True )

                    "ArrowLeft" ->
                        D.succeed ( SetStep (modBy 4 (index - 1)), True )

                    "Home" ->
                        D.succeed ( SetStep 0, True )

                    "End" ->
                        D.succeed ( SetStep 3, True )

                    _ ->
                        D.fail "Not a setup tab navigation key"
            )


setupView : Model -> Html Msg
setupView m =
    let
        r =
            m.request

        title =
            List.drop m.step [ "Size", "Quantity & sheet", "Arrangement", "Bleed" ] |> List.head |> Maybe.withDefault "Size"

        manual =
            Maybe.withDefault { rows = 1, columns = 1, rotationDegrees = 0, margins = Nothing } r.manual

        duplex =
            Maybe.withDefault { flipEdge = A.DuplexFlipEdgeLongEdge, rotateBack180 = False, backAlignment = "" } r.duplex

        source =
            Maybe.map .analysis m.source

        controls =
            case m.step of
                0 ->
                    [ h3 [] [ text "Finished size" ]
                    , div [ class "field-grid two" ] [ numberField m "Finished width (in)" "finished-width" r.finishedCutSize.width, numberField m "Finished height (in)" "finished-height" r.finishedCutSize.height ]
                    , fieldset [ disabled (not (m.chosenWidth && m.chosenHeight) || Dict.member "invalid:finished-width" m.drafts || Dict.member "invalid:finished-height" m.drafts) ]
                        [ selectField "Finished orientation"
                            "finished-orientation"
                            (if r.finishedCutSize.width > r.finishedCutSize.height then
                                "landscape"

                             else
                                "portrait"
                            )
                            [ ( "portrait", "Portrait" ), ( "landscape", "Landscape" ) ]
                        ]
                    , if not m.chosenWidth || not m.chosenHeight then
                        p [ class "field-help" ] [ text "Choose both finished dimensions or apply a preset." ]

                      else
                        text ""
                    , details [] [ summary [] [ text "Presets" ], savedView m ]
                    , section [ class "impose-source-summary" ] [ p [] [ text (String.fromInt (Maybe.withDefault 0 r.sourcePageCount) ++ " pages") ], details [] [ summary [] [ text "Detected artwork details" ], p [] [ text (Maybe.map (\a -> String.fromFloat a.sourcePdfSize.width ++ " × " ++ String.fromFloat a.sourcePdfSize.height ++ " in · " ++ String.fromInt a.orientationAdjustedPages ++ " orientation corrections") source |> Maybe.withDefault "") ], ul [] (Maybe.map (.sourcePages >> List.indexedMap (\i p -> li [] [ text (String.fromInt (i + 1) ++ ": " ++ Maybe.withDefault "Artwork" p.filename ++ " · " ++ String.fromFloat p.sourcePdfSize.width ++ " × " ++ String.fromFloat p.sourcePdfSize.height ++ " in") ])) source |> Maybe.withDefault []) ] ]
                    , details [] [ summary [] [ text "Artwork files" ], queueView m ]
                    , choices "How should these pages print?"
                        "mode"
                        (if r.impositionMode == A.ImpositionModeRepeat then
                            "repeat"

                         else
                            "unique"
                        )
                        [ ( "repeat", "Repeat pages" ), ( "unique", "Use each page once" ) ]
                    ]

                1 ->
                    [ h3 [] [ text "Quantity and sheet" ]
                    , if r.impositionMode == A.ImpositionModeRepeat then
                        div [ class "repeat-quantity-section" ]
                            [ h3 [] [ text "Copy quantities" ]
                            , p [] [ text (String.fromInt r.quantityRequested ++ " total impressions") ]
                            , if List.length (I.quantities r) == 1 then
                                numberField m "Copies" "copies" (toFloat r.quantityRequested)

                              else
                                button [ id "edit-copy-quantities", class "ghost-button", onClick (OpenDialog "quantities") ] [ text "Edit copy quantities" ]
                            ]

                      else
                        text ""
                    , selectField "Print sheet size"
                        "sheet"
                        (if Dict.member "sheet-custom" m.drafts then
                            "custom"

                         else
                            sheetName r.parentSheetSize
                        )
                        [ ( "12x18", "12 × 18 in" ), ( "8.5x11", "8.5 × 11 in" ), ( "11x17", "11 × 17 in" ), ( "13x19", "13 × 19 in" ), ( "custom", "Custom size" ) ]
                    , if Dict.member "sheet-custom" m.drafts || sheetName r.parentSheetSize == "custom" then
                        div [ class "field-grid two" ] [ numberField m "Sheet width (in)" "sheet-width" r.parentSheetSize.width, numberField m "Sheet height (in)" "sheet-height" r.parentSheetSize.height ]

                      else
                        text ""
                    , label [ class "field" ]
                        [ span [] [ text "Printing" ]
                        , select
                            [ attribute "aria-label" "Printing"
                            , value
                                (if r.sides == A.SidesDouble then
                                    "double"

                                 else
                                    "single"
                                )
                            , onInput (Field "sides")
                            ]
                            [ option [ value "single" ] [ text "Single-sided" ], option [ value "double", disabled (modBy 2 (Maybe.withDefault 1 r.sourcePageCount) /= 0) ] [ text "Double-sided" ] ]
                        ]
                    ]

                2 ->
                    [ h3 [] [ text "Arrangement" ]
                    , choices "Sheet arrangements"
                        "layout"
                        (if r.layoutMode == A.LayoutModeManual then
                            "manual"

                         else
                            "maxPieces"
                        )
                        [ ( "maxPieces", "Max per sheet" ), ( "manual", "Custom grid" ) ]
                    , if r.layoutMode == A.LayoutModeManual then
                        div [ class "field-grid two" ] [ numberField m "Rows" "rows" (toFloat manual.rows), numberField m "Columns" "columns" (toFloat manual.columns) ]

                      else
                        text ""
                    , details []
                        [ summary [] [ text "Advanced sheet settings" ]
                        , selectField "Impression orientation" "orientation" (orientationName r.orientationPreference) [ ( "auto", "Auto" ), ( "upright", "Upright" ), ( "quarterTurn", "Quarter-turn" ), ( "portrait", "Portrait" ), ( "landscape", "Landscape" ) ]
                        , div [ class "field-grid two" ] [ numberField m "Horizontal gutter (in)" "gutter-horizontal" r.gutter.horizontal, numberField m "Vertical gutter (in)" "gutter-vertical" r.gutter.vertical ]
                        , if r.sides == A.SidesDouble then
                            div []
                                [ selectField "Duplex flip edge"
                                    "flip"
                                    (if duplex.flipEdge == A.DuplexFlipEdgeLongEdge then
                                        "longEdge"

                                     else
                                        "shortEdge"
                                    )
                                    [ ( "longEdge", "Long edge" ), ( "shortEdge", "Short edge" ) ]
                                , check "Rotate back side 180°" "rotate-back" duplex.rotateBack180
                                ]

                          else
                            text ""
                        , if r.layoutMode == A.LayoutModeManual then
                            div []
                                [ selectField "Item rotation" "rotation" (String.fromInt manual.rotationDegrees) [ ( "0", "0°" ), ( "90", "90°" ) ]
                                , check "Center grid automatically" "center" (manual.margins == Nothing)
                                , case manual.margins of
                                    Nothing ->
                                        text ""

                                    Just margins ->
                                        div [ class "field-grid two" ] [ numberField m "Top margin (in)" "margin-top" margins.top, numberField m "Right margin (in)" "margin-right" margins.right, numberField m "Bottom margin (in)" "margin-bottom" margins.bottom, numberField m "Left margin (in)" "margin-left" margins.left ]
                                ]

                          else
                            text ""
                        ]
                    ]

                _ ->
                    [ h3 [] [ text "Edge artwork" ]
                    , p [ class "bleed-status" ]
                        [ text
                            (if r.sourceBleedOverride /= Nothing then
                                "Manual PDF bleed"

                             else if Maybe.map (.likelyBleed >> .detected) source |> Maybe.withDefault False then
                                "Detected PDF bleed"

                             else
                                "No uniform bleed detected"
                            )
                        ]
                    , case r.sourceBleedOverride of
                        Nothing ->
                            btn "Enter bleed manually" (Field "source-bleed" "0.125")

                        Just amount ->
                            div [] [ numberField m "PDF bleed per side (in)" "source-bleed" amount, btn "Clear manual amount" (Toggle "clear-bleed") ]
                    , choices "Artwork at the cut line"
                        "bleed"
                        (if r.bleedOption == A.BleedOptionScaleToBleed then
                            "scaleToBleed"

                         else
                            "useAsIs"
                        )
                        [ ( "useAsIs", "Keep fitted placement" ), ( "scaleToBleed", "Scale to add bleed" ) ]
                    , if r.bleedOption == A.BleedOptionScaleToBleed then
                        numberField m "Extend per side (in)" "created-bleed" r.createdBleedAmount

                      else
                        text ""
                    ]
    in
    section [ id "gang-setup-panel", class "gang-panel gang-setup elm-setup", attribute "aria-label" "Print setup" ]
        [ nav [ class "setup-stepper", attribute "aria-label" "Print setup" ]
            [ ol [ attribute "role" "tablist", attribute "aria-label" "Print setup options" ]
                (List.indexedMap
                    (\i t ->
                        li [ attribute "role" "presentation" ]
                            [ button
                                [ type_ "button"
                                , id ("setup-tab-" ++ String.fromInt i)
                                , attribute "role" "tab"
                                , attribute "aria-controls" "setup-tab-panel"
                                , attribute "aria-selected"
                                    (if i == m.step then
                                        "true"

                                     else
                                        "false"
                                    )
                                , tabindex
                                    (if i == m.step then
                                        0

                                     else
                                        -1
                                    )
                                , onClick (SetStep i)
                                , preventDefaultOn "keydown" (setupTabKey i)
                                ]
                                [ span [ class "setup-step-label" ] [ text t ] ]
                            ]
                    )
                    [ "Size", "Quantity & sheet", "Arrangement", "Bleed" ]
                )
            ]
        , fieldset [ class "gang-setup-fields", disabled m.busy ] [ div [ id "setup-tab-panel", class "setup-step-panel", attribute "role" "tabpanel", attribute "aria-labelledby" ("setup-tab-" ++ String.fromInt m.step), tabindex 0 ] (h3 [ class "visually-hidden" ] [ text title ] :: controls) ]
        , div [ class "setup-step-actions elm-setup-actions" ]
            [ if m.step > 0 then
                btn "Back" (SetStep (m.step - 1))

              else
                text ""
            , if m.step < 3 then
                primary "Continue" (SetStep (m.step + 1)) False

              else
                primary "Download imposed PDF" Submit (not (setupValid m) || m.busy || not m.layoutReady)
            ]
        , if m.step == 3 then
            details [ class "elm-saved-footer" ] [ summary [] [ text "Saved work" ], savedView m ]

          else
            text ""
        ]


sheetName : A.SizeInches -> String
sheetName s =
    if s.width == 12 && s.height == 18 then
        "12x18"

    else if s.width == 8.5 && s.height == 11 then
        "8.5x11"

    else if s.width == 11 && s.height == 17 then
        "11x17"

    else if s.width == 13 && s.height == 19 then
        "13x19"

    else
        "custom"


orientationName : A.OrientationPreference -> String
orientationName o =
    case o of
        A.OrientationPreferenceUpright ->
            "upright"

        A.OrientationPreferenceQuarterTurn ->
            "quarterTurn"

        A.OrientationPreferencePortrait ->
            "portrait"

        A.OrientationPreferenceLandscape ->
            "landscape"

        _ ->
            "auto"


fitFor : Model -> A.ArtworkFit
fitFor m =
    let
        own =
            if m.perArtwork then
                List.filter (\p -> p.pageNumber == m.selectedPage) m.request.pageOverrides |> List.head |> Maybe.andThen .artworkFit

            else
                Nothing
    in
    case own of
        Just fit ->
            fit

        Nothing ->
            Maybe.withDefault { mode = A.ArtworkFitModeContain, position = { x = 0.5, y = 0.5 } } m.request.artworkFit


toolbarView : Model -> Html Msg
toolbarView m =
    let
        fit =
            fitFor m

        size =
            if m.perArtwork then
                List.filter (\p -> p.pageNumber == m.selectedPage) m.request.pageOverrides |> List.head |> Maybe.andThen .finishedCutSize |> Maybe.withDefault m.request.finishedCutSize

            else
                m.request.finishedCutSize
    in
    section [ class "impose-workspace-toolbar elm-toolbar", attribute "aria-label" "Artwork and sheet preview controls" ]
        [ btn
            (if m.collapsed then
                "Show setup toolbar"

             else
                "Hide setup toolbar"
            )
            (Toggle "collapse")
        , details [ class "elm-artwork-menu artwork-toolbar-disclosure" ]
            [ summary [ class "ghost-button" ] [ text "Artwork" ]
            , fieldset [ disabled m.busy ]
                [ choices "Artwork fitting"
                    "fit"
                    (case fit.mode of
                        A.ArtworkFitModeCover ->
                            "cover"

                        A.ArtworkFitModeStretch ->
                            "stretch"

                        _ ->
                            "contain"
                    )
                    [ ( "contain", "Fit" ), ( "cover", "Fill" ), ( "stretch", "Stretch" ) ]
                , selectField "Impression orientation" "orientation" (orientationName m.request.orientationPreference) [ ( "auto", "Auto · best sheet fit" ), ( "upright", "Upright · 0°" ), ( "quarterTurn", "Quarter-turn · 90°" ) ]
                , selectField "Selected artwork" "page" (String.fromInt m.selectedPage) (List.range 1 (Maybe.withDefault 1 m.request.sourcePageCount) |> List.map (\i -> ( String.fromInt i, "Page " ++ String.fromInt i )))
                , check "Adjust only selected artwork" "per-artwork" m.perArtwork
                , if m.perArtwork then
                    div [] [ div [ class "field-grid two" ] [ numberField m "Artwork finished width (in)" "artwork-width" size.width, numberField m "Artwork finished height (in)" "artwork-height" size.height ], btn "Use shared settings for this artwork" (Toggle "clear-override") ]

                  else
                    text ""
                , if fit.mode == A.ArtworkFitModeCover then
                    div [] [ p [] [ text "Crop position" ], div [ class "field-grid two" ] [ numberField m "Horizontal position" "crop-x" fit.position.x, numberField m "Vertical position" "crop-y" fit.position.y ], label [ class "field" ] [ span [] [ text "Horizontal crop" ], input [ type_ "range", Html.Attributes.min "0", Html.Attributes.max "1", Html.Attributes.step "0.01", value (String.fromFloat fit.position.x), onInput (Field "crop-x") ] [] ], label [ class "field" ] [ span [] [ text "Vertical crop" ], input [ type_ "range", Html.Attributes.min "0", Html.Attributes.max "1", Html.Attributes.step "0.01", value (String.fromFloat fit.position.y), onInput (Field "crop-y") ] [] ], div [ class "crop-anchor-grid", attribute "role" "group", attribute "aria-label" "Crop position anchors" ] (List.map (\( x, y, title ) -> button [ type_ "button", attribute "aria-label" title, Html.Attributes.title title, onClick (CropAnchor x y) ] [ span [ attribute "aria-hidden" "true" ] [] ]) [ ( 0, 0, "Top left" ), ( 0.5, 0, "Top center" ), ( 1, 0, "Top right" ), ( 0, 0.5, "Middle left" ), ( 0.5, 0.5, "Center" ), ( 1, 0.5, "Middle right" ), ( 0, 1, "Bottom left" ), ( 0.5, 1, "Bottom center" ), ( 1, 1, "Bottom right" ) ]), btn "Reset crop position" (Toggle "crop-reset"), Preview.crop m fit ]

                  else
                    text ""
                ]
            ]
        , div [ class "sheet-preview-nav" ]
            [ button [ type_ "button", class "ghost-button sheet-nav-button previous", attribute "aria-label" "Previous sheet", disabled (m.sheet == 0), onClick (Navigate (Basics.max 0 (m.sheet - 1)) m.back) ] [ span [ class "sheet-nav-label" ] [ text "Previous sheet" ] ]
            , span [] [ text ("Sheet " ++ String.fromInt (m.sheet + 1) ++ " of " ++ String.fromInt (Maybe.map .sheetsRequired m.layout |> Maybe.withDefault 1)) ]
            , button [ type_ "button", class "ghost-button sheet-nav-button next", attribute "aria-label" "Next sheet", disabled (m.sheet + 1 >= (Maybe.map .sheetsRequired m.layout |> Maybe.withDefault 1)), onClick (Navigate (m.sheet + 1) m.back) ] [ span [ class "sheet-nav-label" ] [ text "Next sheet" ] ]
            , if m.request.sides == A.SidesDouble then
                btn
                    (if m.back then
                        "Show front"

                     else
                        "Show back"
                    )
                    (Navigate m.sheet (not m.back))

              else
                text ""
            ]
        , details [] [ summary [] [ text "Preview options" ], fieldset [] [ check "Cut lines" "cut" m.showCut, check "Bleed lines" "bleed-lines" m.showBleed, check "Gutters" "gutters" m.showGutters, check "Cut paths" "paths" m.showPaths, btn "Zoom out" (Toggle "zoom-out"), btn "Zoom in" (Toggle "zoom-in"), btn "Fit sheet" (Toggle "zoom-fit") ] ]
        ]


savedView : Model -> Html Msg
savedView m =
    div [ class "elm-saved" ]
        [ select [ attribute "aria-label" "Apply preset", onInput ApplyPreset ] (option [ value "" ] [ text "Choose a preset" ] :: List.map (\p -> option [ value p.id ] [ text p.name ]) m.presets)
        , label [ class "field" ] [ span [] [ text "Setup name" ], input [ value m.savedName, onInput (Field "name") ] [] ]
        , div [ class "elm-button-row" ]
            [ btn
                (if m.editingPreset == Nothing then
                    "Save preset"

                 else
                    "Update preset"
                )
                (Save "presets")
            , btn "Save as new preset" (Save "new-preset")
            , button [ type_ "button", class "ghost-button", disabled (m.editingPreset == Nothing), onClick (Save "rename-preset") ] [ text "Rename" ]
            , btn "Save recent job" (Save "recent-jobs")
            ]
        , details []
            [ summary [] [ text "Manage presets" ]
            , ul []
                (List.map
                    (\p ->
                        li []
                            [ text p.name
                            , btn "Apply" (ApplyPreset p.id)
                            , if p.builtIn then
                                text ""

                              else
                                btn "Delete" (DeleteSaved "presets" p.id)
                            ]
                    )
                    m.presets
                )
            ]
        , details [] [ summary [] [ text "Recent jobs" ], ul [] (List.map (\p -> li [] [ text p.name, btn "Restore setup" (ApplySaved "recent-jobs" p.id), btn "Delete" (DeleteSaved "recent-jobs" p.id) ]) m.recent) ]
        , details []
            [ summary [] [ text "Export history" ]
            , ul []
                (List.map
                    (\p ->
                        li []
                            [ text p.name
                            , btn "Restore setup" (ApplySaved "export-history" p.id)
                            , if p.hasStoredFile then
                                a [ class "ghost-button", href ("gang-up/export-history/" ++ p.id), download p.outputFilename ] [ text "Download" ]

                              else
                                text ""
                            , btn "Delete" (DeleteSaved "export-history" p.id)
                            ]
                    )
                    m.history
                )
            ]
        ]


dialogView : Model -> Html Msg
dialogView m =
    let
        title =
            case m.dialog of
                "range" ->
                    "Choose a page range"

                "quantities" ->
                    "Edit copy quantities"

                _ ->
                    "Clear all files?"

        count =
            List.sum (List.map .pages m.files)

        issue =
            V.pages count m.rangeDraft |> Result.map (\_ -> "") |> Result.withDefault "Enter valid pages or ranges within this source."

        content =
            case m.dialog of
                "range" ->
                    [ p [] [ text ("This source has " ++ String.fromInt count ++ " pages. Example: 1-3, 5, 8-10") ]
                    , label [ class "field" ] [ span [] [ text "Pages" ], input [ id "range-input", autofocus True, value m.rangeDraft, onInput (Field "range") ] [] ]
                    , if issue /= "" then
                        small [ class "field-error", attribute "role" "alert" ] [ text issue ]

                      else
                        text ""
                    , primary "Apply range" ApplyDialog (issue /= "")
                    ]

                "quantities" ->
                    [ p []
                        [ text
                            (if m.request.sides == A.SidesDouble then
                                "Copies apply per page pair."

                             else
                                "Set a default for every page, then adjust exceptions below."
                            )
                        ]
                    , label [ class "field" ] [ span [] [ text "Copies for all" ], input [ id "bulk-copy-quantity", value m.bulkDraft, attribute "inputmode" "numeric", onInput (Field "bulk") ] [] ]
                    , if Result.toMaybe (V.whole 0 10000 m.bulkDraft) == Nothing then
                        small [ class "field-error", attribute "role" "alert" ] [ text "Enter a whole number from 0 to 10000." ]

                      else
                        text ""
                    , primary "Apply to all" ApplyDialog (Result.toMaybe (V.whole 0 10000 m.bulkDraft) == Nothing)
                    , div [ class "quantity-dialog-list" ]
                        (I.quantities m.request
                            |> List.indexedMap
                                (\i n ->
                                    label [ class "quantity-dialog-row" ]
                                        [ span []
                                            [ text
                                                (if m.request.sides == A.SidesDouble then
                                                    "Pages " ++ String.fromInt (i * 2 + 1) ++ "–" ++ String.fromInt (i * 2 + 2)

                                                 else
                                                    "Page " ++ String.fromInt (i + 1)
                                                )
                                            ]
                                        , input
                                            [ attribute "aria-label" ("Page " ++ String.fromInt (i + 1) ++ " copies")
                                            , attribute "aria-invalid"
                                                (if Result.toMaybe (V.whole 0 10000 (Dict.get i m.quantityDrafts |> Maybe.withDefault (String.fromInt n))) == Nothing then
                                                    "true"

                                                 else
                                                    "false"
                                                )
                                            , value (Dict.get i m.quantityDrafts |> Maybe.withDefault (String.fromInt n))
                                            , attribute "inputmode" "numeric"
                                            , onInput (Quantity i)
                                            ]
                                            []
                                        , if Result.toMaybe (V.whole 0 10000 (Dict.get i m.quantityDrafts |> Maybe.withDefault (String.fromInt n))) == Nothing then
                                            small [ class "field-error" ] [ text "Enter a whole number from 0 to 10000." ]

                                          else
                                            text ""
                                        ]
                                )
                        )
                    , primary "Done" CloseDialog (not (Dict.isEmpty (Dict.filter (\_ v -> Result.toMaybe (V.whole 0 10000 v) == Nothing) m.quantityDrafts)))
                    ]

                _ ->
                    [ p [] [ text "This removes every selected file and resets all tool settings." ], primary "Clear files" ApplyDialog False ]
    in
    node "dialog"
        [ id "workspace-dialog", class "quantity-dialog range-dialog", attribute "aria-labelledby" "dialog-title", preventDefaultOn "cancel" (D.succeed ( CloseDialog, True )) ]
        [ Html.form [ onSubmit ApplyDialog ]
            [ header [ class "quantity-dialog-head" ] [ h2 [ id "dialog-title" ] [ text title ], button [ type_ "button", class "quantity-dialog-close", attribute "aria-label" "Close dialog", onClick CloseDialog ] [ text "×" ] ]
            , div [ class "elm-dialog-content" ] content
            , footer [ class "quantity-dialog-actions" ]
                [ btn
                    (if m.dialog == "clear" then
                        "Keep working"

                     else
                        "Cancel"
                    )
                    CloseDialog
                ]
            ]
        ]
