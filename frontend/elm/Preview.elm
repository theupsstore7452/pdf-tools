module Preview exposing (crop, view)

import Api.Generated as A
import Dict
import Html exposing (Html, button, div, p, text)
import Html.Attributes as H
import Html.Events exposing (onClick)
import Imposition as I
import Model exposing (..)
import Svg as S
import Svg.Attributes as SA


f : Float -> String
f =
    String.fromFloat


rect : String -> A.PlanRect -> List (S.Attribute Msg)
rect cls r =
    [ SA.class cls, SA.x (f r.x), SA.y (f r.y), SA.width (f r.width), SA.height (f r.height) ]


view : Model -> Html Msg
view m =
    div [ H.id "gang-preview-panel", H.class "gang-preview-region elm-preview-region", H.attribute "aria-label" "Sheet preview" ]
        [ div [ H.class "gang-panel gang-preview" ]
            [ div [ H.class "sheet-stage elm-sheet-stage" ]
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
                        S.svg [ SA.class "sheet-svg", SA.viewBox ("-0.3 -0.3 " ++ f (sheet.width + 0.6) ++ " " ++ f (sheet.height + 0.6)), SA.style ("transform: scale(" ++ f m.zoom ++ "); transform-origin:center;"), H.attribute "role" "img", H.attribute "aria-label" "Production sheet" ]
                            (S.rect [ SA.class "sheet-paper", SA.x "0", SA.y "0", SA.width (f sheet.width), SA.height (f sheet.height), SA.fill "white" ] [] :: List.map (placement m display) l.placements)
                , if m.previewLoading then
                    p [ H.class "preview-cache-status", H.attribute "role" "status" ] [ text "Updating preview…" ]

                  else
                    text ""
                , if m.previewError /= "" then
                    div [ H.class "preview-cache-status", H.attribute "role" "alert" ] [ text m.previewError, button [ H.type_ "button", H.class "ghost-button", H.disabled m.busy, onClick RetryPreview ] [ text "Retry preview" ] ]

                  else
                    text ""
                ]
            ]
        , case m.layout of
            Nothing ->
                text ""

            Just l ->
                div [ H.class "elm-preview-summary" ] [ p [] [ text (String.fromInt l.piecesPerSheet ++ " pieces per sheet · " ++ String.fromInt l.sheetsRequired ++ " sheets · " ++ String.fromInt l.totalPiecesProduced ++ " pieces produced · " ++ String.fromInt l.extraPiecesProduced ++ " extra") ], div [] (List.map (\w -> p [ H.class "field-help" ] [ text (w.problem ++ " " ++ w.impact ++ " " ++ w.fix) ]) l.warnings) ]
        ]


placement : Model -> Display -> A.PiecePlacement -> Html Msg
placement m display item =
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

        duplex =
            l.duplex

        rotateBack =
            display.back && (Maybe.map .rotateBack180 duplex |> Maybe.withDefault False)

        landscape =
            l.parentSheetSize.width > l.parentSheetSize.height

        baseX =
            Maybe.map
                (\d ->
                    if d.flipEdge == A.DuplexFlipEdgeLongEdge then
                        not landscape

                    else
                        landscape
                )
                duplex
                |> Maybe.withDefault False

        mirrorX =
            baseX /= rotateBack

        mirrorY =
            baseX == rotateBack

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

        cx =
            cut.x + cut.width / 2

        cy =
            cut.y + cut.height / 2

        artwork =
            Maybe.map .artwork plan |> Maybe.withDefault { x = 0, y = 0, width = size.width, height = size.height }

        image0 =
            { x = cx - size.width / 2 + artwork.x, y = cy - size.height / 2 + artwork.y, width = artwork.width, height = artwork.height }

        image =
            case Maybe.andThen .previewBox plan of
                Nothing ->
                    image0

                Just box ->
                    let
                        source =
                            Maybe.map .sourcePdfSize plan |> Maybe.withDefault l.sourcePdfSize

                        sx =
                            image0.width / source.width

                        sy =
                            image0.height / source.height
                    in
                    { x = image0.x + box.left * sx, y = image0.y + (source.height - box.top) * sy, width = box.width * sx, height = box.height * sy }

        bleed =
            Maybe.map .bleedAmount plan |> Maybe.withDefault l.bleed.effectiveAmountPerSide

        clip =
            { x = cut.x - bleed, y = cut.y - bleed, width = cut.width + 2 * bleed, height = cut.height + 2 * bleed }

        clipId =
            "piece-clip-" ++ String.fromInt item.index

        rotation =
            l.rotationDegrees
                + (if rotateBack then
                    180

                   else
                    0
                  )

        url =
            page |> Maybe.andThen (\n -> Dict.get n display.urls)
    in
    if page == Nothing then
        S.g [] []

    else
        S.g []
            [ S.defs [] [ S.clipPath [ SA.id clipId ] [ S.rect (rect "" clip) [] ] ]
            , S.g [ SA.clipPath ("url(#" ++ clipId ++ ")") ]
                [ case url of
                    Nothing ->
                        S.rect (rect "" cut ++ [ SA.fill "#eef1f2" ]) []

                    Just src ->
                        S.image (rect "piece-artwork" image ++ [ SA.xlinkHref src, SA.preserveAspectRatio "none", SA.transform ("rotate(" ++ String.fromInt rotation ++ " " ++ f cx ++ " " ++ f cy ++ ")") ]) []
                ]
            , if m.showBleed then
                S.rect (rect "piece-bleed" clip ++ [ SA.fill "none", SA.stroke "#b54d78", SA.strokeWidth "0.008", SA.strokeDasharray "0.04 0.02" ]) []

              else
                S.g [] []
            , if m.showCut then
                S.rect (rect "piece-cut" cut ++ [ SA.fill "none", SA.stroke "#2d6f7f", SA.strokeWidth "0.012" ]) []

              else
                S.g [] []
            , if m.showGutters then
                S.rect [ SA.x (f item.x), SA.y (f item.y), SA.width (f item.width), SA.height (f item.height), SA.fill "none", SA.stroke "#b99845", SA.strokeWidth "0.015", SA.strokeDasharray "0.05" ] []

              else
                S.g [] []
            , if m.showPaths then
                S.g [] [ S.line [ SA.x1 "0", SA.x2 (f l.parentSheetSize.width), SA.y1 (f cut.y), SA.y2 (f cut.y), SA.stroke "#ba5545", SA.strokeWidth "0.008" ] [], S.line [ SA.x1 (f cut.x), SA.x2 (f cut.x), SA.y1 "0", SA.y2 (f l.parentSheetSize.height), SA.stroke "#ba5545", SA.strokeWidth "0.008" ] [] ]

              else
                S.g [] []
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

        artwork =
            case plan |> Maybe.andThen .previewBox of
                Nothing ->
                    artwork0

                Just box ->
                    let
                        source =
                            Maybe.map .sourcePdfSize plan |> Maybe.withDefault m.request.sourcePdfSize

                        sx =
                            artwork0.width / source.width

                        sy =
                            artwork0.height / source.height
                    in
                    { x = artwork0.x + box.left * sx, y = artwork0.y + (source.height - box.top) * sy, width = box.width * sx, height = box.height * sy }

        travel =
            Maybe.map .positionTravel plan |> Maybe.withDefault { x = 0, y = 0 }
    in
    div [ H.class "elm-crop-editor", H.attribute "data-crop-x" (f fit.position.x), H.attribute "data-crop-y" (f fit.position.y), H.attribute "data-travel-x" (f travel.x), H.attribute "data-travel-y" (f travel.y), H.attribute "data-cut-width" (f size.width), H.attribute "data-cut-height" (f size.height), H.attribute "aria-label" "Drag artwork to position the crop" ]
        [ S.svg [ SA.viewBox ("0 0 " ++ f size.width ++ " " ++ f size.height), SA.width "100%", SA.height "100%" ]
            [ S.rect [ SA.width (f size.width), SA.height (f size.height), SA.fill "white" ] []
            , case url of
                Just src ->
                    S.image (rect "" artwork ++ [ SA.xlinkHref src, SA.preserveAspectRatio "none" ]) []

                Nothing ->
                    S.g [] []
            , S.rect [ SA.width (f size.width), SA.height (f size.height), SA.fill "none", SA.stroke "#2d6f7f", SA.strokeWidth "0.03" ] []
            ]
        ]
