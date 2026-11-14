module Preview exposing (crop, view)

import Api.Generated as A
import Da.Button as Button
import Dict
import Html exposing (Html, details, div, h3, p, span, strong, summary, text)
import Html.Attributes as H
import Html.Events exposing (onClick, onFocus)
import Imposition as I
import Model exposing (..)
import Set
import Svg as S
import Svg.Attributes as SA


f : Float -> String
f =
    String.fromFloat


rect : String -> A.PlanRect -> List (S.Attribute Msg)
rect cls r =
    SA.class cls :: rectGeometry r


rectGeometry : A.PlanRect -> List (S.Attribute Msg)
rectGeometry r =
    [ SA.x (f r.x), SA.y (f r.y), SA.width (f r.width), SA.height (f r.height) ]


view : Model -> Html Msg
view m =
    div [ H.id "gang-preview-panel", H.class "gang-preview-region elm-preview-region", H.attribute "role" "tabpanel", H.attribute "aria-labelledby" "gang-preview-tab" ]
        [ div [ H.class "gang-panel gang-preview", H.style "display" "flex", H.style "flex-direction" "column" ]
            [ inspectionControls m
            , duplexInstructions m
            , div [ H.class "sheet-stage elm-sheet-stage", H.style "flex" "1", H.style "height" "auto" ]
                [ div
                    [ H.id "preview-sheet-viewport"
                    , H.class "preview-sheet-viewport"
                    , H.attribute "role" "region"
                    , H.attribute "aria-label" "Sheet inspection; scroll to inspect enlarged artwork"
                    , H.tabindex 0
                    , H.style "position" "absolute"
                    , H.style "inset" "0"
                    , H.style "overflow" "auto"
                    ]
                    [ div
                        [ H.class "preview-sheet-canvas"
                        , H.style "position" "relative"
                        , H.style "width" (String.fromInt m.previewZoom ++ "%")
                        , H.style "height" (String.fromInt m.previewZoom ++ "%")
                        , H.attribute "data-preview-zoom" (String.fromInt m.previewZoom)
                        ]
                        [ case m.display of
                            Nothing ->
                                p [] [ text "Rendering artwork preview…" ]

                            Just display ->
                                let
                                    l =
                                        display.layout

                                    sheet =
                                        l.parentSheetSize
                                in
                                S.svg [ SA.class "sheet-svg", SA.viewBox ("-0.3 -0.3 " ++ f (sheet.width + 0.6) ++ " " ++ f (sheet.height + 0.6)), H.attribute "role" "group", H.attribute "aria-label" "Production sheet" ]
                                    (S.rect [ SA.class "sheet-paper", SA.x "0", SA.y "0", SA.width (f sheet.width), SA.height (f sheet.height), SA.fill "white" ] []
                                        :: (List.map (placement True m display) l.placements ++ [ guides m display ])
                                    )
                        ]
                    ]
                , if m.previewLoading then
                    p [ H.class "preview-cache-status", H.attribute "role" "status" ] [ text "Updating preview…" ]

                  else
                    text ""
                ]
            , duplexProof m
            , Button.view []
                { variant = Button.Primary, disabled = m.busy, busy = False, className = "preview-review-action" }
                "Review and download"
                (SetStep 2)
            ]
        , artworkMenu m
        ]


inspectionControls : Model -> Html Msg
inspectionControls m =
    let
        unavailable =
            m.display == Nothing

        zoomIn =
            [ 100, 150, 200, 300 ]
                |> List.filter (\zoom -> zoom > m.previewZoom)
                |> List.head
                |> Maybe.withDefault 300

        zoomOut =
            [ 300, 200, 150, 100 ]
                |> List.filter (\zoom -> zoom < m.previewZoom)
                |> List.head
                |> Maybe.withDefault 100

        action cls disabled label msg =
            Button.view [ H.attribute "aria-controls" "preview-sheet-viewport" ]
                { variant = Button.Quiet, disabled = unavailable || disabled, busy = False, className = cls }
                label
                msg

        legendItem cls label =
            span [ H.class "preview-guide-legend-item" ]
                [ span [ H.class ("preview-guide-swatch " ++ cls), H.attribute "aria-hidden" "true" ] []
                , text label
                ]
    in
    div [ H.class "preview-inspection" ]
        [ div [ H.class "preview-zoom-controls", H.attribute "role" "group", H.attribute "aria-label" "Preview zoom" ]
            [ action "preview-zoom-out" (m.previewZoom <= 100) "Zoom out" (SetPreviewZoom zoomOut)
            , span [ H.class "preview-zoom-status", H.attribute "role" "status", H.attribute "aria-atomic" "true" ] [ text (String.fromInt m.previewZoom ++ "% of fit") ]
            , action "preview-zoom-in" (m.previewZoom >= 300) "Zoom in" (SetPreviewZoom zoomIn)
            , action "preview-fit" (m.previewZoom == 100) "Fit to sheet" FitPreview
            ]
        , details [ H.class "preview-guide-options" ]
            [ summary [] [ text "Guide options" ]
            , div [ H.class "preview-guide-controls" ]
                [ Button.view
                    [ H.attribute "aria-controls" "preview-sheet-viewport"
                    , H.attribute "aria-pressed"
                        (if m.previewGuides then
                            "true"

                         else
                            "false"
                        )
                    ]
                    { variant = Button.Quiet, disabled = unavailable, busy = False, className = "preview-guides-toggle" }
                    "Show guides"
                    TogglePreviewGuides
                , div
                    [ H.class "preview-guide-legend"
                    , H.attribute "role" "group"
                    , H.attribute "aria-label" "Preview guide legend"
                    , H.attribute "data-guides-visible"
                        (if m.previewGuides then
                            "true"

                         else
                            "false"
                        )
                    ]
                    [ legendItem "preview-guide-swatch-cut" "Cut line"
                    , legendItem "preview-guide-swatch-bleed" "Bleed outline (when present)"
                    ]
                ]
            , p [ H.class "preview-inspection-help" ] [ text "100% fits the sheet. Zoom and guides affect this preview only; they do not change your PDF." ]
            ]
        ]


duplexInstructions : Model -> Html Msg
duplexInstructions m =
    case m.display of
        Just display ->
            case display.layout.duplex of
                Just duplex ->
                    let
                        page =
                            display.sheet
                                * 2
                                + (if display.back then
                                    2

                                   else
                                    1
                                  )

                        direction =
                            if I.backMirrorsX display.layout then
                                "left to right"

                            else
                                "top to bottom"
                    in
                    div [ H.class "duplex-instructions", H.attribute "role" "status" ]
                        [ strong [] [ text ("Print double-sided · Flip on " ++ I.printerFlip duplex) ]
                        , p [] [ text ("Actual size (100%). Turn the sheet " ++ direction ++ ".") ]
                        , span [ H.class "duplex-sheet-label" ]
                            [ text
                                ((if display.back then
                                    "Back sheet"

                                  else
                                    "Front sheet"
                                 )
                                    ++ " · PDF page "
                                    ++ String.fromInt page
                                )
                            ]
                        , if m.previewLoading || not m.layoutReady then
                            p [] [ text "Updating print setup…" ]

                          else
                            text ""
                        ]

                Nothing ->
                    text ""

        Nothing ->
            text ""


duplexProof : Model -> Html Msg
duplexProof m =
    case m.display of
        Just display ->
            let
                l =
                    display.layout

                selected =
                    l.placements
                        |> List.filter (\item -> I.pageNumber l display.sheet False item.index /= Nothing)
                        |> (\items -> List.filter (\item -> Just item.index == m.selectedImpression) items |> List.head |> Maybe.withDefault (List.head items |> Maybe.withDefault { index = 0, row = 0, column = 0, x = 0, y = 0, width = 0, height = 0, finishedX = 0, finishedY = 0, finishedWidth = 0, finishedHeight = 0 }))

                proof back =
                    let
                        side =
                            { display | back = back }

                        cut =
                            finishedCut side selected

                        page =
                            I.pageNumber l display.sheet back selected.index |> Maybe.withDefault 1

                        size =
                            l.pagePlans |> List.filter (\plan -> plan.pageNumber == page) |> List.head |> Maybe.map .finishedCutSize |> Maybe.withDefault l.finishedCutSize

                        turn =
                            if back then
                                l.rotationDegrees
                                    - (if I.backMirrorsX l then
                                        0

                                       else
                                        180
                                      )

                            else
                                -l.rotationDegrees

                        label =
                            (if back then
                                "Back"

                             else
                                "Front"
                            )
                                ++ " · Page "
                                ++ String.fromInt page
                    in
                    div [ H.class "duplex-proof-side" ]
                        [ span [] [ text label ]
                        , S.svg [ SA.class "duplex-proof-image", SA.viewBox ("0 0 " ++ f size.width ++ " " ++ f size.height), H.attribute "role" "img", H.attribute "aria-label" (label ++ " after cutting") ]
                            [ S.rect [ SA.width (f size.width), SA.height (f size.height), SA.fill "white" ] []
                            , S.g [ SA.transform ("translate(" ++ f (size.width / 2) ++ " " ++ f (size.height / 2) ++ ") rotate(" ++ String.fromInt turn ++ ") translate(" ++ f -(cut.x + cut.width / 2) ++ " " ++ f -(cut.y + cut.height / 2) ++ ")") ]
                                [ placement False m side selected ]
                            ]
                        ]
            in
            if l.duplex == Nothing then
                text ""

            else
                details [ H.class "duplex-proof", H.attribute "open" "" ]
                    [ summary [] [ text "Check finished front & back" ]
                    , div [ H.class "duplex-proof-content" ]
                        [ div [ H.class "duplex-proof-copy" ]
                            [ h3 [] [ text ("Finished piece " ++ String.fromInt (selected.index + 1)) ]
                            , p [] [ text "Shown after cutting and turning the piece left to right. Select a piece on the sheet to check its pair." ]
                            , p [] [ text "Print one test sheet to confirm your printer settings before the full run." ]
                            ]
                        , div [ H.class "duplex-proof-pair" ] [ proof False, proof True ]
                        ]
                    ]

        Nothing ->
            text ""


artworkMenu : Model -> Html Msg
artworkMenu m =
    let
        page =
            Maybe.withDefault m.selectedPage m.artworkMenu

        rotation =
            I.artworkRotation page m.request

        action label value =
            Button.view [ H.attribute "role" "menuitem" ] { variant = Button.Quiet, disabled = m.busy || value == rotation, busy = False, className = "" } label (RotateArtwork page value)
    in
    div [ H.id "artwork-context-menu", H.class "artwork-context-menu", H.attribute "popover" "auto", H.attribute "role" "menu", H.attribute "aria-label" ("Page " ++ String.fromInt page ++ " artwork actions") ]
        [ p [ H.class "artwork-context-heading", H.attribute "role" "presentation" ] [ text ("Page " ++ String.fromInt page ++ " · " ++ String.fromInt rotation ++ "°") ]
        , action "Rotate clockwise 90°" (modBy 360 (rotation + 90))
        , action "Rotate counterclockwise 90°" (modBy 360 (rotation + 270))
        , action "Rotate 180°" (modBy 360 (rotation + 180))
        , action "Reset rotation" 0
        , p [ H.class "field-help", H.attribute "role" "presentation" ] [ text "Applies to all copies of this page." ]
        ]


sourceImage : Maybe A.PagePlan -> A.PlanRect -> ( A.PlanRect, String )
sourceImage plan artwork =
    let
        rotation =
            Maybe.map .rotationDegrees plan |> Maybe.withDefault 0

        quarterTurn =
            modBy 180 rotation == 90

        width =
            if quarterTurn then
                artwork.height

            else
                artwork.width

        height =
            if quarterTurn then
                artwork.width

            else
                artwork.height

        cx =
            artwork.x + artwork.width / 2

        cy =
            artwork.y + artwork.height / 2

        full =
            { x = cx - width / 2, y = cy - height / 2, width = width, height = height }

        image =
            case Maybe.andThen .previewBox plan of
                Nothing ->
                    full

                Just box ->
                    let
                        source =
                            Maybe.map .sourcePdfSize plan |> Maybe.withDefault { width = width, height = height }

                        sx =
                            width / source.width

                        sy =
                            height / source.height
                    in
                    { x = full.x + box.left * sx, y = full.y + (source.height - box.top) * sy, width = box.width * sx, height = box.height * sy }
    in
    ( image, "rotate(" ++ String.fromInt rotation ++ " " ++ f cx ++ " " ++ f cy ++ ")" )


guides : Model -> Display -> Html Msg
guides m display =
    let
        sheet =
            display.layout.parentSheetSize

        cuts =
            display.layout.placements
                |> List.filter (\item -> I.pageNumber display.layout display.sheet display.back item.index /= Nothing)
                |> List.map (finishedCut display)

        unique =
            Set.fromList >> Set.toList

        horizontal =
            cuts
                |> List.concatMap (\cut -> [ cut.y, cut.y + cut.height ])
                |> unique
                |> List.map (\y -> [ SA.x1 "0", SA.x2 (f sheet.width), SA.y1 (f y), SA.y2 (f y) ])

        vertical =
            cuts
                |> List.concatMap (\cut -> [ cut.x, cut.x + cut.width ])
                |> unique
                |> List.map (\x -> [ SA.x1 (f x), SA.x2 (f x), SA.y1 "0", SA.y2 (f sheet.height) ])

        selected =
            display.layout.placements
                |> List.filter (\item -> m.selectedImpression == Just item.index && I.pageNumber display.layout display.sheet display.back item.index /= Nothing)
                |> List.concatMap
                    (\item ->
                        [ S.rect (rect "piece-selection-halo preview-guide" (finishedCut display item)) []
                        , S.rect (rect "piece-selection preview-guide" (finishedCut display item) ++ [ H.attribute "data-impression-index" (String.fromInt item.index) ]) []
                        ]
                    )

        outlined shape cls attrs =
            [ shape (SA.class ("preview-guide preview-guide-halo " ++ cls ++ "-halo") :: attrs) []
            , shape (SA.class ("preview-guide " ++ cls) :: attrs) []
            ]

        bleeds =
            display.layout.placements
                |> List.filterMap
                    (\item ->
                        I.pageNumber display.layout display.sheet display.back item.index
                            |> Maybe.andThen
                                (\page ->
                                    let
                                        amount =
                                            display.layout.pagePlans
                                                |> List.filter (\plan -> plan.pageNumber == page)
                                                |> List.head
                                                |> Maybe.map .bleedAmount
                                                |> Maybe.withDefault display.layout.bleed.effectiveAmountPerSide

                                        cut =
                                            finishedCut display item
                                    in
                                    if amount > 0 then
                                        Just
                                            (outlined S.rect
                                                "piece-bleed-bound"
                                                (rectGeometry { x = cut.x - amount, y = cut.y - amount, width = cut.width + 2 * amount, height = cut.height + 2 * amount }
                                                    ++ [ H.attribute "data-impression-index" (String.fromInt item.index), H.attribute "data-bleed-amount" (f amount) ]
                                                )
                                            )

                                    else
                                        Nothing
                                )
                    )
                |> List.concat
    in
    S.g [ SA.class "sheet-guides", H.attribute "aria-hidden" "true" ]
        ((if m.previewGuides then
            bleeds ++ List.concatMap (outlined S.line "piece-cut-path") (horizontal ++ vertical)

          else
            []
         )
            ++ selected
        )


finishedCut : Display -> A.PiecePlacement -> A.PlanRect
finishedCut display item =
    let
        l =
            display.layout

        page =
            I.pageNumber l display.sheet display.back item.index

        plan =
            page |> Maybe.andThen (\n -> List.filter (\p -> p.pageNumber == n) l.pagePlans |> List.head)

        size =
            Maybe.map .finishedCutSize plan |> Maybe.withDefault l.finishedCutSize

        rotated =
            l.rotationDegrees == 90

        width =
            if rotated then
                size.height

            else
                size.width

        height =
            if rotated then
                size.width

            else
                size.height

        cut0 =
            { x = item.finishedX + (item.finishedWidth - width) / 2, y = item.finishedY + (item.finishedHeight - height) / 2, width = width, height = height }

        mirrorX =
            I.backMirrorsX l

        mirrorY =
            not mirrorX

        cut =
            { cut0
                | x =
                    if display.back && mirrorX then
                        l.parentSheetSize.width - cut0.x - width

                    else
                        cut0.x
                , y =
                    if display.back && mirrorY then
                        l.parentSheetSize.height - cut0.y - height

                    else
                        cut0.y
            }
    in
    cut


placement : Bool -> Model -> Display -> A.PiecePlacement -> Html Msg
placement interactive m display item =
    let
        l =
            display.layout

        page =
            I.pageNumber l display.sheet display.back item.index

        plan =
            page |> Maybe.andThen (\n -> List.filter (\p -> p.pageNumber == n) l.pagePlans |> List.head)

        size =
            Maybe.map .finishedCutSize plan |> Maybe.withDefault l.finishedCutSize

        cut =
            finishedCut display item

        cx =
            cut.x + cut.width / 2

        cy =
            cut.y + cut.height / 2

        artwork =
            Maybe.map .artwork plan |> Maybe.withDefault { x = 0, y = 0, width = size.width, height = size.height }

        image0 =
            { x = cx - size.width / 2 + artwork.x, y = cy - size.height / 2 + artwork.y, width = artwork.width, height = artwork.height }

        ( image, sourceTransform ) =
            sourceImage plan image0

        bleed =
            Maybe.map .bleedAmount plan |> Maybe.withDefault l.bleed.effectiveAmountPerSide

        clip =
            { x = cut.x - bleed, y = cut.y - bleed, width = cut.width + 2 * bleed, height = cut.height + 2 * bleed }

        clipId =
            (if interactive then
                "piece-clip-"

             else if display.back then
                "proof-back-clip-"

             else
                "proof-front-clip-"
            )
                ++ String.fromInt item.index

        rotation =
            I.sideRotation l display.back

        url =
            page |> Maybe.andThen (\n -> Dict.get n display.urls)
    in
    if page == Nothing then
        S.g [] []

    else
        S.g
            (if interactive then
                [ H.id ("sheet-item-" ++ String.fromInt item.index)
                , SA.class "sheet-item"
                , H.attribute "data-impression-index" (String.fromInt item.index)
                , H.attribute "data-selected"
                    (if m.selectedImpression == Just item.index then
                        "true"

                     else
                        "false"
                    )
                , onClick (SelectImpression item.index (Maybe.withDefault 1 page))
                , onFocus (SelectImpression item.index (Maybe.withDefault 1 page))
                , H.attribute "data-artwork-page" (String.fromInt (Maybe.withDefault 1 page))
                , H.attribute "data-artwork-disabled"
                    (if m.busy || not m.layoutReady || m.previewLoading then
                        "true"

                     else
                        "false"
                    )
                , H.attribute "tabindex" "0"
                , H.attribute "role" "button"
                , H.attribute "aria-label" ("Page " ++ String.fromInt (Maybe.withDefault 1 page) ++ " artwork actions")
                , H.attribute "aria-haspopup" "menu"
                ]

             else
                [ SA.class "proof-artwork", H.attribute "aria-hidden" "true" ]
            )
            [ S.defs [] [ S.clipPath [ SA.id clipId ] [ S.rect (rect "" clip) [] ] ]
            , S.g [ SA.clipPath ("url(#" ++ clipId ++ ")") ]
                [ case url of
                    Nothing ->
                        S.rect (rect "" cut ++ [ SA.fill "#eef1f2" ]) []

                    Just src ->
                        S.g [ SA.transform ("rotate(" ++ String.fromInt rotation ++ " " ++ f cx ++ " " ++ f cy ++ ")") ] [ S.image (rect "piece-artwork" image ++ [ SA.xlinkHref src, SA.preserveAspectRatio "none", SA.transform sourceTransform ]) [] ]
                ]
            , S.rect (rect "piece-hit-area" cut ++ [ SA.fill "transparent", H.attribute "vector-effect" "non-scaling-stroke" ]) []
            ]


crop : Model -> A.ArtworkFit -> Html Msg
crop m fit =
    let
        page =
            m.selectedPage

        plan =
            m.layout |> Maybe.andThen (\l -> List.filter (\p -> p.pageNumber == page) l.pagePlans |> List.head)

        size =
            Maybe.map .finishedCutSize plan |> Maybe.withDefault m.request.finishedCutSize

        url =
            m.display |> Maybe.andThen (\d -> Dict.get page d.urls)

        artwork0 =
            Maybe.map .artwork plan |> Maybe.withDefault { x = 0, y = 0, width = size.width, height = size.height }

        ( artwork, sourceTransform ) =
            sourceImage plan artwork0

        travel =
            Maybe.map .positionTravel plan |> Maybe.withDefault { x = 0, y = 0 }
    in
    div [ H.class "elm-crop-editor", H.attribute "data-crop-x" (f fit.position.x), H.attribute "data-crop-y" (f fit.position.y), H.attribute "data-travel-x" (f travel.x), H.attribute "data-travel-y" (f travel.y), H.attribute "data-cut-width" (f size.width), H.attribute "data-cut-height" (f size.height), H.attribute "aria-label" "Drag artwork to position the crop" ]
        [ S.svg [ SA.viewBox ("0 0 " ++ f size.width ++ " " ++ f size.height), SA.width "100%", SA.height "100%" ]
            [ S.rect [ SA.width (f size.width), SA.height (f size.height), SA.fill "white" ] []
            , case url of
                Just src ->
                    S.image (rect "" artwork ++ [ SA.xlinkHref src, SA.preserveAspectRatio "none", SA.transform sourceTransform ]) []

                Nothing ->
                    S.g [] []
            , S.rect [ SA.width (f size.width), SA.height (f size.height), SA.fill "none", SA.stroke "#2d6f7f", SA.strokeWidth "0.03" ] []
            ]
        ]
