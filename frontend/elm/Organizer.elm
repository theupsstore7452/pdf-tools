module Organizer exposing (count, identity, order, remapRequest, view, visible)

import Api.Generated as A
import Da.Button as Button
import Da.Field as Field
import Da.Reorderable as Reorderable
import Dict
import File
import Html exposing (Html, details, div, form, h1, img, p, section, span, summary, text)
import Html.Attributes exposing (alt, attribute, class, classList, disabled, draggable, id, src, tabindex, title, type_)
import Html.Events exposing (onClick, onSubmit)
import Imposition as I
import Model exposing (..)


count : Model -> Int
count m =
    List.sum (List.map (\f -> max 1 f.pages) m.files)


identity : Model -> List Int
identity m =
    List.range 1 (count m)


order : Model -> List Int
order m =
    if List.isEmpty m.pageOrder then
        identity m

    else
        m.pageOrder


visible : Model -> List Int
visible m =
    m.pageDraft |> List.drop (m.pageBatch * 12) |> List.take 12


origin : Model -> Int -> ( String, Int )
origin m page =
    let
        find files n =
            case files of
                [] ->
                    ( "Artwork", n )

                file :: rest ->
                    if n <= max 1 file.pages then
                        ( File.name file.file, n )

                    else
                        find rest (n - max 1 file.pages)
    in
    find m.files page


remapRequest : List Int -> List Int -> A.LayoutRequest -> A.LayoutRequest
remapRequest before after r =
    let
        oldPosition =
            before |> List.indexedMap (\n id -> ( id, n )) |> Dict.fromList

        newPosition =
            after |> List.indexedMap (\n id -> ( id, n )) |> Dict.fromList

        oldPages =
            before |> List.indexedMap Tuple.pair |> Dict.fromList

        quantities =
            I.quantities r |> List.indexedMap Tuple.pair |> Dict.fromList

        overrides =
            r.pageOverrides |> List.filterMap (\p -> Dict.get (p.pageNumber - 1) oldPages |> Maybe.andThen (\id -> Dict.get id newPosition) |> Maybe.map (\n -> { p | pageNumber = n + 1 }))

        pairs pages =
            let
                loop remaining accumulated =
                    case remaining of
                        front :: back :: rest ->
                            loop rest (( front, back ) :: accumulated)

                        _ ->
                            List.reverse accumulated
            in
            loop pages []

        oldPairs =
            pairs before |> List.indexedMap (\n pair -> ( pair, n )) |> Dict.fromList

        nextQs =
            if r.sides == A.SidesDouble then
                pairs after |> List.map (\pair -> Dict.get pair oldPairs |> Maybe.andThen (\n -> Dict.get n quantities) |> Maybe.withDefault 1)

            else
                after |> List.map (\id -> Dict.get id oldPosition |> Maybe.andThen (\n -> Dict.get n quantities) |> Maybe.withDefault 1)
    in
    { r
        | pageOverrides = overrides
        , impressionQuantities =
            if r.impositionMode == A.ImpositionModeRepeat then
                Just nextQs

            else
                Nothing
        , quantityRequested =
            if r.impositionMode == A.ImpositionModeRepeat then
                List.sum nextQs

            else
                List.length after
                    // (if r.sides == A.SidesDouble then
                            2

                        else
                            1
                       )
    }


button : String -> Msg -> Bool -> Html Msg
button label msg blocked =
    Button.view [] { variant = Button.Secondary, disabled = blocked, busy = False, className = "" } label msg


view : Model -> Html Msg
view m =
    let
        total =
            count m

        lastBatch =
            max 0 ((total - 1) // 12)

        selected =
            origin m m.pageSelected

        item page =
            let
                ( filename, sourcePage ) =
                    origin m page

                position =
                    m.pageDraft |> List.indexedMap Tuple.pair |> List.filter (\( _, p ) -> p == page) |> List.head |> Maybe.map (Tuple.first >> (+) 1) |> Maybe.withDefault 1

                label =
                    filename ++ ", page " ++ String.fromInt sourcePage
            in
            { id = String.fromInt page
            , label = label
            , content =
                Html.button
                    [ type_ "button"
                    , classList [ ( "page-tile", True ), ( "page-tile-selected", page == m.pageSelected ) ]
                    , attribute "aria-pressed"
                        (if page == m.pageSelected then
                            "true"

                         else
                            "false"
                        )
                    , attribute "aria-label" ("Select " ++ label)
                    , onClick (PageSelected page)
                    , disabled m.busy
                    ]
                    [ span [ class "page-position" ] [ text ("Position " ++ String.fromInt position) ]
                    , div [ class "page-thumbnail" ]
                        [ case Dict.get page m.pageThumbnails of
                            Just url ->
                                img [ src url, alt "", draggable "false" ] []

                            Nothing ->
                                div [ class "page-thumbnail-placeholder" ] [ text ("Page " ++ String.fromInt sourcePage) ]
                        ]
                    , span [ class "page-origin", title filename ] [ text filename ]
                    , span [ class "page-source-number" ] [ text ("Original page " ++ String.fromInt sourcePage) ]
                    ]
            }
    in
    section [ class "page-organizer", attribute "aria-label" "Organize pages" ]
        [ div [ class "page-organizer-heading" ]
            [ h1 [ id "page-organizer-title", tabindex -1 ] [ text "Organize pages" ]
            , p [] [ text "Reorder pages for every tool. Drag a page, use the arrows, or move it to a position." ]
            , if m.request.sides == A.SidesDouble && m.operation == Impose then
                p [ class "page-pair-note" ] [ text "Every two consecutive pages form a front/back pair. Copies stay with intact pairs; new pairs start with one copy." ]

              else
                text ""
            ]
        , details [ class "page-organizer-controls", id "page-order-actions" ]
            [ summary [] [ text "Move, reverse, or reset pages" ]
            , div [ class "page-organizer-action-fields" ]
                [ form [ class "page-move-form", onSubmit MovePage ]
                    [ span [ class "page-selected-name", title (Tuple.first selected) ] [ text (Tuple.first selected ++ " · Page " ++ String.fromInt (Tuple.second selected)) ]
                    , Field.present Field.Inline [] (Field.input [] (Field.config "page-position-input" "Move to position") { value = m.pagePosition, onInput = PagePosition, kind = Field.Integer })
                    , button "Move page" MovePage (m.busy || (String.toInt m.pagePosition |> Maybe.map (\n -> n < 1 || n > total) |> Maybe.withDefault True))
                    ]
                , div [ class "page-order-actions" ] [ button "Reverse order" (PageCommand "reverse") m.busy, button "Restore original order" (PageCommand "reset") m.busy ]
                ]
            ]
        , div [ class "page-organizer-content" ]
            [ if m.pageError /= "" then
                div [ class "page-preview-error", attribute "role" "status" ] [ p [] [ text m.pageError ], button "Retry thumbnails" (PageBatch m.pageBatch) m.busy ]

              else
                text ""
            , if m.pageLoading then
                p [ class "page-loading", attribute "role" "status" ] [ text "Loading page thumbnails… You can organize pages while they load." ]

              else
                text ""
            , Reorderable.view []
                { id = "organized-pages", label = "Page order", moveUp = "Move earlier", moveDown = "Move later" }
                { items = List.map item (visible m), state = m.pageOrderState, disabled = m.busy, onChange = PageOrderChanged }
            ]
        , div [ class "page-organizer-footer" ]
            [ div [ class "page-organizer-pagination" ]
                [ Button.view [ attribute "aria-label" "Previous pages" ] { variant = Button.Secondary, disabled = m.busy || m.pageBatch == 0, busy = False, className = "" } "Previous" (PageBatch (m.pageBatch - 1))
                , span [ attribute "role" "status" ] [ text (String.fromInt (m.pageBatch * 12 + 1) ++ "–" ++ String.fromInt (min total ((m.pageBatch + 1) * 12)) ++ " of " ++ String.fromInt total) ]
                , Button.view [ attribute "aria-label" "Next pages" ] { variant = Button.Secondary, disabled = m.busy || m.pageBatch == lastBatch, busy = False, className = "" } "Next" (PageBatch (m.pageBatch + 1))
                ]
            , div [ class "page-organizer-save" ]
                [ Button.view [ attribute "aria-label" "Cancel page ordering" ] { variant = Button.Secondary, disabled = False, busy = False, className = "" } "Cancel" ClosePages
                , Button.view [] { variant = Button.Primary, disabled = m.busy, busy = False, className = "" } "Apply page order" ApplyPageOrder
                ]
            ]
        ]
