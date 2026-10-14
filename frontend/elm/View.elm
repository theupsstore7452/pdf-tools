module View exposing (dropdownSubscriptions, revealDropdown, view)

import Api.Generated as A
import Da.Button as Button
import Da.Card as Card
import Da.Dialog as Dialog
import Da.Dropdown as Dropdown
import Da.Feedback as Feedback
import Da.Field as DaField
import Da.FileList as FileList
import Da.Menu as Menu
import Da.Popover as Popover
import Da.Theme as Theme
import Da.ThemeToggle as ThemeToggle
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


toolSelector : Model -> Html Msg
toolSelector m =
    nav [ class "app-brand app-tool-selector", attribute "aria-label" "Tools" ]
        [ DaField.present DaField.Compact [] (dropdownView (toolDropdown m)) ]


btn : String -> Msg -> Html Msg
btn title message =
    Button.content [] { variant = Button.Secondary, disabled = False, busy = False, className = "ghost-button" } [ text title ] message


primary : String -> Msg -> Bool -> Html Msg
primary title message blocked =
    Button.content [] { variant = Button.Primary, disabled = blocked, busy = False, className = "primary-button" } [ text title ] message


setupArrow : Bool -> Html Msg
setupArrow forward =
    Svg.svg [ SA.viewBox "0 0 24 24", SA.width "20", SA.height "20", attribute "aria-hidden" "true", attribute "focusable" "false" ]
        [ Svg.path
            [ SA.d
                (if forward then
                    "M5 12h14m-6-6 6 6-6 6"

                 else
                    "M19 12H5m6-6-6 6 6 6"
                )
            , SA.fill "none"
            , SA.stroke "currentColor"
            , SA.strokeWidth "2"
            , SA.strokeLinecap "round"
            , SA.strokeLinejoin "round"
            ]
            []
        ]


choices : String -> String -> String -> List ( String, String ) -> Html Msg
choices title key selected options =
    DaField.segmented []
        (DaField.config key title)
        { value = selected, onSelect = Field key, options = fieldOptions options }


fieldOptions : List ( String, String ) -> List DaField.SelectOption
fieldOptions =
    List.map (\( value, title ) -> { value = value, label = title, disabled = False })


dropdownControl : Model -> DaField.Config -> String -> List ( String, String ) -> ( DaField.Config, Dropdown.Control Msg )
dropdownControl m config selected options =
    ( config
    , { value = selected
      , state = Dict.get config.id m.dropdowns |> Maybe.withDefault Dropdown.initial
      , options = fieldOptions options
      , onChange = DropdownChanged config.id selected
      }
    )


toolDropdown : Model -> ( DaField.Config, Dropdown.Control Msg )
toolDropdown m =
    let
        config =
            DaField.config "tool" "Tool"
    in
    dropdownControl m { config | disabled = m.busy } (operationLabel m.operation) (List.map (\op -> ( operationLabel op, operationLabel op )) (operations m.files))


orientationDropdown : Model -> ( DaField.Config, Dropdown.Control Msg )
orientationDropdown m =
    let
        config =
            DaField.config "finished-orientation" "Finished orientation"
    in
    dropdownControl m
        { config | disabled = m.busy || not (m.chosenWidth && m.chosenHeight) || Dict.member "invalid:finished-width" m.drafts || Dict.member "invalid:finished-height" m.drafts }
        (if m.request.finishedCutSize.width > m.request.finishedCutSize.height then
            "landscape"

         else
            "portrait"
        )
        [ ( "portrait", "Portrait" ), ( "landscape", "Landscape" ) ]


sheetDropdown : Model -> ( DaField.Config, Dropdown.Control Msg )
sheetDropdown m =
    dropdownControl m
        (DaField.config "sheet" "Print sheet size")
        (if Dict.member "sheet-custom" m.drafts then
            "custom"

         else
            sheetName m.request.parentSheetSize
        )
        [ ( "12x18", "12 × 18 in" ), ( "8.5x11", "8.5 × 11 in" ), ( "11x17", "11 × 17 in" ), ( "13x19", "13 × 19 in" ), ( "custom", "Custom size" ) ]


printingDropdown : Model -> ( DaField.Config, Dropdown.Control Msg )
printingDropdown m =
    let
        ( config, control ) =
            dropdownControl m
                (DaField.config "sides" "Printing")
                (if m.request.sides == A.SidesDouble then
                    "double"

                 else
                    "single"
                )
                [ ( "single", "Single-sided" ), ( "double", "Double-sided" ) ]
    in
    ( config
    , { control | options = List.map (\option -> { option | disabled = option.value == "double" && modBy 2 (Maybe.withDefault 1 m.request.sourcePageCount) /= 0 }) control.options }
    )


flipDropdown : Model -> ( DaField.Config, Dropdown.Control Msg )
flipDropdown m =
    dropdownControl m
        (DaField.config "flip" "Duplex flip edge")
        (if Maybe.map .flipEdge m.request.duplex == Just A.DuplexFlipEdgeShortEdge then
            "shortEdge"

         else
            "longEdge"
        )
        [ ( "longEdge", "Long edge" ), ( "shortEdge", "Short edge" ) ]


presetDropdown : Model -> ( DaField.Config, Dropdown.Control Msg )
presetDropdown m =
    dropdownControl m
        (DaField.config "apply-preset" "Apply preset")
        (Maybe.withDefault "" m.editingPreset)
        (( "", "Choose a preset" ) :: List.map (\preset -> ( preset.id, preset.name )) m.presets)


dropdownView : ( DaField.Config, Dropdown.Control Msg ) -> Html Msg
dropdownView ( config, control ) =
    Dropdown.view [] config control


visibleDropdowns : Model -> List ( DaField.Config, Dropdown.Control Msg )
visibleDropdowns m =
    if List.isEmpty m.files then
        []

    else
        toolDropdown m
            :: (if m.operation == Impose && m.source /= Nothing then
                    (if m.presetsOpen then
                        [ presetDropdown m ]

                     else
                        []
                    )
                        ++ (if m.rail == "preview" then
                                []

                            else if m.step == 0 then
                                [ orientationDropdown m ]

                            else if m.step == 1 then
                                [ sheetDropdown m, printingDropdown m ]
                                    ++ (if m.request.sides == A.SidesDouble then
                                            [ flipDropdown m ]

                                        else
                                            []
                                       )

                            else
                                []
                           )

                else
                    []
               )


dropdownSubscriptions : Model -> Sub Msg
dropdownSubscriptions m =
    visibleDropdowns m |> List.map (\( config, control ) -> Dropdown.subscriptions config control) |> Sub.batch


revealDropdown : String -> Model -> Cmd Msg
revealDropdown key m =
    visibleDropdowns m
        |> List.filter (\( config, _ ) -> config.id == key)
        |> List.map (\( config, control ) -> Dropdown.reveal config.id control (\_ -> NoOp))
        |> Cmd.batch


check : String -> String -> Bool -> Html Msg
check title key state =
    DaField.checkbox []
        (DaField.config key title)
        { checked = state, onCheck = \_ -> Toggle key }


numberField : Model -> String -> String -> Float -> Html Msg
numberField m title key n =
    let
        config =
            DaField.config key title

        draft =
            Dict.get key m.drafts
                |> Maybe.withDefault
                    (if (key == "finished-width" && not m.chosenWidth) || (key == "finished-height" && not m.chosenHeight) then
                        ""

                     else
                        String.fromFloat n
                    )
    in
    DaField.input []
        { config | error = Dict.get ("invalid:" ++ key) m.drafts }
        { value = draft, onInput = Field key, kind = DaField.Decimal }


textField : String -> String -> String -> (String -> Msg) -> Html Msg
textField key title draft change =
    DaField.input [] (DaField.config key title) { value = draft, onInput = change, kind = DaField.Text }


view : Model -> Html Msg
view m =
    Theme.root
        (if m.theme == "dark" then
            Theme.Dark

         else
            Theme.Light
        )
        (id "pdf-ui" :: Theme.accent "#2563eb")
        [ appView m ]


appView : Model -> Html Msg
appView m =
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
                    [ if m.operation == Impose then
                        imposeView m

                      else
                        genericView m
                    ]
                ]
        , statusView m
        , if m.dialog == "" then
            text ""

          else
            dialogView m
        ]


headerView : Model -> Html Msg
headerView m =
    header [ class "app-header" ]
        [ toolSelector m
        , workspaceActions m
        ]


workspaceActions : Model -> Html Msg
workspaceActions m =
    let
        base =
            Menu.config "workspace-actions" "Workspace actions" "workspace-actions-trigger" (SetWorkspaceMenu False)

        config =
            { base | open = m.workspaceMenu }

        fileLabel =
            if m.operation == Impose then
                "artwork"

            else
                "files"
    in
    div [ class "app-header-actions" ]
        [ div [ class "app-workspace-selector" ]
            [ Menu.dropdownTrigger [] config "Workspace" (SetWorkspaceMenu (not m.workspaceMenu)) ]
        , themeToggle m
        , Menu.view []
            config
            [ { id = "add", label = "Add " ++ fileLabel, disabled = m.busy, onSelect = WorkspaceAction "add" }
            , { id = "replace", label = "Replace " ++ fileLabel, disabled = m.busy, onSelect = WorkspaceAction "replace" }
            , { id = "clear", label = "Clear workspace", disabled = m.busy, onSelect = WorkspaceAction "clear" }
            ]
        ]


themeToggle : Model -> Html Msg
themeToggle m =
    ThemeToggle.view
        [ attribute "role" "switch"
        , attribute "aria-checked"
            (if m.theme == "dark" then
                "true"

             else
                "false"
            )
        ]
        { mode =
            if m.theme == "dark" then
                Theme.Dark

            else
                Theme.Light
        , label = "Dark mode"
        , onChange = \_ -> Toggle "theme"
        }


statusView : Model -> Html Msg
statusView m =
    Keyed.node "aside"
        [ class "toast-region", attribute "aria-label" "Notifications" ]
        ([ if m.busy then
            Just
                ( "progress"
                , div [ class "toast toast-progress" ]
                    [ div [ class "toast-progress-label", attribute "role" "status", attribute "aria-atomic" "true" ]
                        [ span [] [ text m.phase ], span [] [ text (String.fromInt m.progress ++ "%") ] ]
                    , Feedback.progress [] { label = m.phase, value = Just m.progress }
                    , Button.content []
                        { variant = Button.Secondary, disabled = False, busy = False, className = "toast-action" }
                        [ text
                            (if m.phase == "Checking PDFs" then
                                "Cancel inspection"

                             else
                                "Cancel"
                            )
                        ]
                        Cancel
                    ]
                )

           else
            Nothing
         , m.toast
            |> Maybe.map
                (\toast ->
                    ( String.fromInt toast.id
                    , div [ class "toast" ]
                        [ p
                            [ attribute "role"
                                (if List.member toast.kind [ "error", "preview" ] then
                                    "alert"

                                 else
                                    "status"
                                )
                            , attribute "aria-atomic" "true"
                            ]
                            [ text toast.message ]
                        , div [ class "toast-actions" ]
                            [ if List.member toast.kind [ "error", "cancel", "preview" ] then
                                Button.content []
                                    { variant = Button.Secondary, disabled = m.busy, busy = False, className = "toast-action" }
                                    [ text
                                        (if toast.kind == "preview" then
                                            "Retry preview"

                                         else
                                            "Retry"
                                        )
                                    ]
                                    (if toast.kind == "preview" then
                                        RetryPreview

                                     else
                                        Retry
                                    )

                              else
                                text ""
                            , Button.content [ attribute "aria-label" "Dismiss notification" ] { variant = Button.Quiet, disabled = False, busy = False, className = "toast-dismiss" } [ text "×" ] (DismissToast toast.id)
                            ]
                        ]
                    )
                )
         ]
            |> List.filterMap identity
        )


emptyView : Model -> Html Msg
emptyView m =
    div [ class "home-view" ]
        [ div [ class "home-content" ]
            [ header [ class "home-header" ] [ h1 [] [ text "PDF Tools" ], themeToggle m ]
            , Card.view [ id "upload-card", attribute "aria-label" "Upload files" ]
                [ div [ class "empty-state-content" ]
                    [ div [ class "empty-intro" ] [ h2 [] [ text "Drop your files here" ] ]
                    , Button.content [ id "browse-files", attribute "aria-describedby" "empty-state-description" ] { variant = Button.Primary, disabled = m.busy, busy = False, className = "primary-button" } [ text "Browse files" ] (Browse False)
                    , p [ id "empty-state-description", class "empty-formats" ] [ text "PDF, PNG, and JPEG supported" ]
                    ]
                ]
            ]
        ]


queueView : Model -> Html Msg
queueView m =
    section [ classList [ ( "file-queue", True ), ( "single-file", List.length m.files == 1 ) ], attribute "aria-label" "Selected files" ]
        [ div [ class "file-queue-head" ]
            [ div [ class "queue-heading" ] [ h2 [] [ text "Files" ], span [ class "count-badge" ] [ text (String.fromInt (List.length m.files)) ] ]
            ]
        , FileList.view []
            { id = "file-queue", label = "Selected files", moveUp = "Move up", moveDown = "Move down", remove = "Remove" }
            { items =
                List.map
                    (\f ->
                        { id = String.fromInt f.id
                        , name = File.name f.file
                        , detail =
                            Just
                                (if isPdf f.file then
                                    String.fromInt f.pages
                                        ++ (if f.pages == 1 then
                                                " page"

                                            else
                                                " pages"
                                           )

                                 else
                                    "300 DPI"
                                )
                        }
                    )
                    m.files
            , state = m.fileOrder
            , disabled = m.busy
            , onChange = Reordered
            , onRemove = \id -> String.toInt id |> Maybe.map Remove |> Maybe.withDefault NoOp
            }
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
            , div [ class "page-selection-actions" ]
                [ Button.content
                    [ attribute "aria-pressed"
                        (if current == "all" then
                            "true"

                         else
                            "false"
                        )
                    ]
                    { variant = Button.Secondary, disabled = False, busy = False, className = "" }
                    [ text "All pages" ]
                    (Field "pages" "all")
                , Button.content
                    [ id "range-trigger"
                    , attribute "aria-haspopup" "dialog"
                    , attribute "aria-pressed"
                        (if current /= "all" then
                            "true"

                         else
                            "false"
                        )
                    ]
                    { variant = Button.Secondary, disabled = False, busy = False, className = "" }
                    [ text "Page range" ]
                    (OpenDialog "range")
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
                        let
                            config =
                                DaField.config "extract-chunk-size" "Pages per chunk"
                        in
                        DaField.input []
                            { config
                                | description = Just "Consecutive groups of selected pages."
                                , error =
                                    if validChunk then
                                        Nothing

                                    else
                                        Just "Enter a whole number from 1 to 1000."
                            }
                            { value = m.chunk, onInput = Field "chunk", kind = DaField.Integer }

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
    div [ classList [ ( "workspace-grid ordered-files", True ), ( "file-action-workspace", List.member m.operation [ Merge, ImagePdf ] ) ] ]
        [ queueView m
        , Html.form [ class "tool-form", attribute "aria-label" (Model.operationLabel m.operation ++ " settings"), onSubmit Submit ]
            [ fieldset [ class "tool-form-fields", disabled m.busy ] fields
            , div [ class "submit-row" ] [ Button.submitContent [] { variant = Button.Primary, disabled = m.busy || not validPages || not validChunk, busy = False, className = "primary-button" } [ text action ] ]
            ]
        ]


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
        [ if m.source == Nothing then
            div [ class "impose-preparation-region" ]
                [ p [] [ text "Prepare your selected artwork to open the sheet." ]
                , if not m.busy then
                    primary "Retry preparation" Retry False

                  else
                    text ""
                ]

          else
            div [ classList [ ( "gang-grid", True ), ( "elm-impose-grid", True ), ( "elm-preview-active", m.rail == "preview" ) ] ]
                [ div [ class "gang-rail-switcher", attribute "role" "tablist", attribute "aria-label" "Imposition workspace sections" ]
                    [ Button.content
                        [ id "gang-setup-tab"
                        , attribute "role" "tab"
                        , attribute "aria-selected"
                            (if m.rail /= "preview" then
                                "true"

                             else
                                "false"
                            )
                        ]
                        { variant = Button.Secondary, disabled = False, busy = False, className = "" }
                        [ text "Setup" ]
                        (SetRail "setup")
                    , Button.content
                        [ id "gang-preview-tab"
                        , attribute "role" "tab"
                        , attribute "aria-selected"
                            (if m.rail == "preview" then
                                "true"

                             else
                                "false"
                            )
                        ]
                        { variant = Button.Secondary, disabled = False, busy = False, className = "" }
                        [ text "Preview" ]
                        (SetRail "preview")
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
                        D.succeed ( SetStep (modBy 3 (index + 1)), True )

                    "ArrowLeft" ->
                        D.succeed ( SetStep (modBy 3 (index - 1)), True )

                    "Home" ->
                        D.succeed ( SetStep 0, True )

                    "End" ->
                        D.succeed ( SetStep 2, True )

                    _ ->
                        D.fail "Not a setup tab navigation key"
            )


setupView : Model -> Html Msg
setupView m =
    let
        r =
            m.request

        title =
            List.drop m.step [ "Size", "Sheet", "Bleed" ] |> List.head |> Maybe.withDefault "Size"

        manual =
            Maybe.withDefault { rows = 1, columns = 1, rotationDegrees = 0, margins = Nothing } r.manual

        duplex =
            Maybe.withDefault { flipEdge = A.DuplexFlipEdgeLongEdge, rotateBack180 = False, backAlignment = "" } r.duplex

        source =
            Maybe.map .analysis m.source

        detectedBleed =
            source |> Maybe.map .likelyBleed

        hasDetectedBleed =
            detectedBleed |> Maybe.map .detected |> Maybe.withDefault False

        detectedAmount =
            detectedBleed |> Maybe.map .amountPerSide |> Maybe.withDefault 0

        bleedAmount =
            Maybe.withDefault detectedAmount r.sourceBleedOverride

        controls =
            case m.step of
                0 ->
                    [ h3 [] [ text "Finished size" ]
                    , div [ class "field-grid two" ] [ numberField m "Width (in)" "finished-width" r.finishedCutSize.width, numberField m "Height (in)" "finished-height" r.finishedCutSize.height ]
                    , dropdownView (orientationDropdown m)
                    , h3 [] [ text "Arrangement" ]
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
                    , if not m.chosenWidth || not m.chosenHeight then
                        p [ class "field-help" ] [ text "Choose both finished dimensions or apply a preset." ]

                      else
                        text ""
                    , section [ class "impose-artwork-files", attribute "aria-label" "Artwork files" ]
                        [ div [ class "artwork-files-heading" ]
                            [ h3 [] [ text "Artwork files" ]
                            , p [ class "field-help" ]
                                [ text
                                    (String.fromInt (Maybe.withDefault 0 r.sourcePageCount)
                                        ++ (if r.sourcePageCount == Just 1 then
                                                " page of artwork"

                                            else
                                                " pages of artwork"
                                           )
                                    )
                                ]
                            ]
                        , queueView m
                        ]
                    ]

                1 ->
                    [ h3 [] [ text "Quantity and sheet" ]
                    , choices "How should these pages print?"
                        "mode"
                        (if r.impositionMode == A.ImpositionModeRepeat then
                            "repeat"

                         else
                            "unique"
                        )
                        [ ( "unique", "Use each page once" ), ( "repeat", "Repeat pages" ) ]
                    , if r.impositionMode == A.ImpositionModeRepeat then
                        if List.length (I.quantities r) == 1 then
                            numberField m "Copies" "copies" (toFloat r.quantityRequested)

                        else
                            div [ class "repeat-quantity-section", attribute "aria-label" "Copy quantities" ]
                                [ span [ class "quantity-summary-label" ] [ text "Copy quantities" ]
                                , strong [ class "quantity-summary-total" ] [ text (String.fromInt r.quantityRequested ++ " impressions") ]
                                , p [ class "quantity-summary-detail" ]
                                    [ text
                                        (I.quantities r
                                            |> List.take 4
                                            |> List.indexedMap
                                                (\i n ->
                                                    (if r.sides == A.SidesDouble then
                                                        "Pages " ++ String.fromInt (i * 2 + 1) ++ "–" ++ String.fromInt (i * 2 + 2)

                                                     else
                                                        "Page " ++ String.fromInt (i + 1)
                                                    )
                                                        ++ ": "
                                                        ++ String.fromInt n
                                                )
                                            |> String.join " · "
                                        )
                                    , if List.length (I.quantities r) > 4 then
                                        text (" · +" ++ String.fromInt (List.length (I.quantities r) - 4) ++ " more")

                                      else
                                        text ""
                                    ]
                                , Button.content [ id "edit-copy-quantities", attribute "aria-label" "Edit copy quantities", attribute "aria-haspopup" "dialog" ] { variant = Button.Quiet, disabled = False, busy = False, className = "quantity-summary-edit" } [ text "Edit" ] (OpenDialog "quantities")
                                ]

                      else
                        text ""
                    , dropdownView (sheetDropdown m)
                    , if Dict.member "sheet-custom" m.drafts || sheetName r.parentSheetSize == "custom" then
                        div [ class "field-grid two" ] [ numberField m "Sheet width (in)" "sheet-width" r.parentSheetSize.width, numberField m "Sheet height (in)" "sheet-height" r.parentSheetSize.height ]

                      else
                        text ""
                    , dropdownView (printingDropdown m)
                    , details []
                        [ summary [] [ text "Advanced sheet settings" ]
                        , div [ class "field-grid two" ] [ numberField m "Horizontal gutter (in)" "gutter-horizontal" r.gutter.horizontal, numberField m "Vertical gutter (in)" "gutter-vertical" r.gutter.vertical ]
                        , if r.sides == A.SidesDouble then
                            div []
                                [ dropdownView (flipDropdown m)
                                , check "Rotate back side 180°" "rotate-back" duplex.rotateBack180
                                ]

                          else
                            text ""
                        , if r.layoutMode == A.LayoutModeManual then
                            div []
                                [ check "Center grid automatically" "center" (manual.margins == Nothing)
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
                    , details
                        (class "bleed-source-setting"
                            :: (if r.sourceBleedOverride /= Nothing then
                                    [ attribute "open" "" ]

                                else
                                    []
                               )
                        )
                        [ summary [ class "bleed-status" ]
                            [ if hasDetectedBleed && r.sourceBleedOverride == Nothing then
                                span [ class "bleed-detected-check", attribute "aria-hidden" "true" ] [ text "✓" ]

                              else
                                text ""
                            , span [ class "bleed-status-copy" ]
                                [ strong []
                                    [ text
                                        (if r.sourceBleedOverride /= Nothing then
                                            "Manual PDF bleed"

                                         else if hasDetectedBleed then
                                            "PDF bleed detected"

                                         else
                                            "No uniform bleed detected"
                                        )
                                    ]
                                , if hasDetectedBleed || r.sourceBleedOverride /= Nothing then
                                    span [] [ text (String.fromFloat bleedAmount ++ " in per side") ]

                                  else
                                    text ""
                                ]
                            , span [ class "bleed-edit-label" ]
                                [ text
                                    (if hasDetectedBleed || r.sourceBleedOverride /= Nothing then
                                        "Edit"

                                     else
                                        "Enter manually"
                                    )
                                ]
                            ]
                        , numberField m "PDF bleed per side (in)" "source-bleed" bleedAmount
                        , if r.sourceBleedOverride /= Nothing then
                            btn "Use auto-detected bleed" (Toggle "clear-bleed")

                          else
                            text ""
                        ]
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
                    , div [ class "production-notes" ] (Maybe.map (.warnings >> List.map (\w -> p [ class "field-help" ] [ text (w.problem ++ " " ++ w.impact ++ " " ++ w.fix) ])) m.layout |> Maybe.withDefault [])
                    ]
    in
    Keyed.node "section"
        [ id "gang-setup-panel", class "gang-panel gang-setup elm-setup", attribute "aria-label" "Print setup" ]
        [ ( "tabs"
          , nav [ class "setup-stepper", attribute "aria-label" "Print setup" ]
                [ ol [ attribute "role" "tablist", attribute "aria-label" "Print setup options" ]
                    (List.indexedMap
                        (\i t ->
                            li [ attribute "role" "presentation" ]
                                [ Button.content
                                    [ id ("setup-tab-" ++ String.fromInt i)
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
                                    , preventDefaultOn "keydown" (setupTabKey i)
                                    ]
                                    { variant = Button.Secondary, disabled = False, busy = False, className = "" }
                                    [ span [ class "setup-step-label" ] [ text t ] ]
                                    (SetStep i)
                                ]
                        )
                        [ "Size", "Sheet", "Bleed" ]
                    )
                ]
          )
        , ( "fields-" ++ String.fromInt m.step
          , fieldset [ class "gang-setup-fields", disabled m.busy ]
                [ div [ id "setup-tab-panel", class "setup-step-panel", attribute "role" "tabpanel", attribute "aria-labelledby" ("setup-tab-" ++ String.fromInt m.step), tabindex 0 ]
                    (h3 [ class "visually-hidden" ] [ text title ] :: controls)
                ]
          )
        , ( "actions"
          , div [ class "setup-step-actions elm-setup-actions" ]
                [ Button.content [ attribute "aria-label" "Back", Html.Attributes.title "Previous setup step" ] { variant = Button.Secondary, disabled = m.step == 0 || m.busy, busy = False, className = "da-button--icon ghost-button setup-back-button" } [ setupArrow False ] (SetStep (m.step - 1))
                , if m.step == 2 then
                    Button.content [] { variant = Button.Primary, disabled = not (setupValid m) || m.busy || not m.layoutReady, busy = False, className = "primary-button setup-download-button" } [ text "Download imposed PDF" ] Submit

                  else
                    text ""
                , Button.content [ attribute "aria-label" "Continue", Html.Attributes.title "Next setup step" ] { variant = Button.Primary, disabled = m.step == 2 || m.busy, busy = False, className = "da-button--icon primary-button setup-continue-button" } [ setupArrow True ] (SetStep (m.step + 1))
                ]
          )
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


toolbarView : Model -> Html Msg
toolbarView m =
    let
        fit =
            Maybe.withDefault { mode = A.ArtworkFitModeContain, position = { x = 0.5, y = 0.5 } } m.request.artworkFit

        base =
            Popover.config "impose-presets" "Saved impose settings" "impose-presets-trigger" (SetPresetsOpen False)

        presets =
            { base | open = m.presetsOpen }

        fitting =
            DaField.config "fit" "Artwork fitting"

        fittingDescription =
            "Fit keeps proportions and shows all artwork. Fill keeps proportions and crops to fill the finished size. Stretch scales width and height independently; this can distort artwork."
    in
    section [ class "impose-workspace-toolbar elm-toolbar", attribute "aria-label" "Artwork and sheet preview controls" ]
        [ div [ class "artwork-fitting", Html.Attributes.title fittingDescription ]
            [ DaField.segmented []
                { fitting | disabled = m.busy, description = Just fittingDescription }
                { value =
                    case fit.mode of
                        A.ArtworkFitModeContain ->
                            "contain"

                        A.ArtworkFitModeCover ->
                            "cover"

                        A.ArtworkFitModeStretch ->
                            "stretch"
                , onSelect = Field "fit"
                , options = fieldOptions [ ( "contain", "Fit" ), ( "cover", "Fill" ), ( "stretch", "Stretch" ) ]
                }
            ]
        , div [ class "preview-side-controls", attribute "role" "group", attribute "aria-label" "Preview side" ]
            [ if m.request.sides == A.SidesDouble then
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
        , div [ class "elm-preview-controls" ]
            [ div [ class "sheet-preview-nav" ]
                [ span [ class "sheet-nav-status", attribute "role" "status" ] [ text ("Sheet " ++ String.fromInt (m.sheet + 1) ++ " of " ++ String.fromInt (Maybe.map .sheetsRequired m.layout |> Maybe.withDefault 1)) ]
                , Button.content [ attribute "aria-label" "Previous sheet" ] { variant = Button.Secondary, disabled = m.sheet == 0, busy = False, className = "ghost-button sheet-nav-button previous" } [ span [ class "sheet-nav-label" ] [ text "Previous sheet" ] ] (Navigate (Basics.max 0 (m.sheet - 1)) m.back)
                , Button.content [ attribute "aria-label" "Next sheet" ] { variant = Button.Secondary, disabled = m.sheet + 1 >= (Maybe.map .sheetsRequired m.layout |> Maybe.withDefault 1), busy = False, className = "ghost-button sheet-nav-button next" } [ span [ class "sheet-nav-label" ] [ text "Next sheet" ] ] (Navigate (m.sheet + 1) m.back)
                ]
            ]
        , div [ class "elm-presets-menu" ]
            [ Popover.trigger [] presets "Presets" (SetPresetsOpen (not m.presetsOpen))
            , Popover.view [] presets [ savedView m ]
            ]
        ]


savedView : Model -> Html Msg
savedView m =
    div [ class "elm-saved" ]
        [ dropdownView (presetDropdown m)
        , textField "setup-name" "Setup name" m.savedName (Field "name")
        , div [ class "elm-button-row" ]
            [ btn
                (if m.editingPreset == Nothing then
                    "Save preset"

                 else
                    "Update preset"
                )
                (Save "presets")
            , btn "Save as new preset" (Save "new-preset")
            , Button.content [] { variant = Button.Secondary, disabled = m.editingPreset == Nothing, busy = False, className = "ghost-button" } [ text "Rename" ] (Save "rename-preset")
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
                    , textField "range-input" "Pages" m.rangeDraft (Field "range")
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
                    , DaField.input
                        [ preventDefaultOn "keydown"
                            (D.field "key" D.string
                                |> D.andThen
                                    (\key ->
                                        if key == "Enter" then
                                            D.succeed ( ApplyDialog, True )

                                        else
                                            D.fail "Not Enter"
                                    )
                            )
                        ]
                        (DaField.config "bulk-copy-quantity" "Copies for all")
                        { value = m.bulkDraft, onInput = Field "bulk", kind = DaField.Integer }
                    , if Result.toMaybe (V.whole 0 10000 m.bulkDraft) == Nothing then
                        small [ class "field-error", attribute "role" "alert" ] [ text "Enter a whole number from 0 to 10000." ]

                      else
                        text ""
                    , primary "Apply to all" ApplyDialog (Result.toMaybe (V.whole 0 10000 m.bulkDraft) == Nothing)
                    , div [ class "quantity-dialog-list" ]
                        (I.quantities m.request
                            |> List.indexedMap
                                (\i n ->
                                    let
                                        draft =
                                            Dict.get i m.quantityDrafts |> Maybe.withDefault (String.fromInt n)

                                        config =
                                            DaField.config ("page-copies-" ++ String.fromInt i)
                                                (if m.request.sides == A.SidesDouble then
                                                    "Pages " ++ String.fromInt (i * 2 + 1) ++ "–" ++ String.fromInt (i * 2 + 2) ++ " copies"

                                                 else
                                                    "Page " ++ String.fromInt (i + 1) ++ " copies"
                                                )
                                    in
                                    DaField.input []
                                        { config
                                            | error =
                                                if Result.toMaybe (V.whole 0 10000 draft) == Nothing then
                                                    Just "Enter a whole number from 0 to 10000."

                                                else
                                                    Nothing
                                        }
                                        { value = draft, onInput = Quantity i, kind = DaField.Integer }
                                )
                        )
                    , primary "Done" CloseDialog (not (Dict.isEmpty (Dict.filter (\_ v -> Result.toMaybe (V.whole 0 10000 v) == Nothing) m.quantityDrafts)))
                    ]

                _ ->
                    [ p [] [ text "This removes every selected file and resets all tool settings." ], primary "Clear files" ApplyDialog False ]
    in
    let
        config =
            Dialog.config "workspace-dialog" title CloseDialog
    in
    Dialog.view []
        { config
            | open = True
            , initialFocus =
                Just
                    (if m.dialog == "range" then
                        "range-input"

                     else if m.dialog == "quantities" then
                        "bulk-copy-quantity"

                     else
                        "button"
                    )
        }
        { body = [ Html.form [ class "elm-dialog-content", onSubmit ApplyDialog ] content ]
        , actions =
            [ btn
                (if m.dialog == "clear" then
                    "Keep working"

                 else
                    "Cancel"
                )
                CloseDialog
            ]
        }
