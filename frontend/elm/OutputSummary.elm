module OutputSummary exposing (generic, imposed, selectedCount)

import Dict
import Model exposing (..)
import Organizer
import Validation as V


plural : Int -> String -> String -> String
plural count one many =
    String.fromInt count
        ++ " "
        ++ (if count == 1 then
                one

            else
                many
           )


selectedCount : Model -> Maybe Int
selectedCount m =
    let
        total =
            List.sum (List.map .pages m.files)

        selection =
            if m.operation == Split then
                m.extractPages

            else
                m.imagePages
    in
    if selection == "all" then
        Just total

    else
        V.pages total selection |> Result.toMaybe |> Maybe.map List.length


generic : Model -> String
generic m =
    let
        pages =
            List.sum (List.map .pages m.files)

        selected =
            selectedCount m

        dpi =
            case m.quality of
                "print" ->
                    "300"

                "high" ->
                    "600"

                _ ->
                    "144"
    in
    case m.operation of
        PdfImage ->
            selected
                |> Maybe.map
                    (\count ->
                        plural count "page" "pages"
                            ++ " → "
                            ++ (if count == 1 && (List.length m.files == 1 || (m.pageOrder /= [] && m.pageOrder /= Organizer.identity m)) then
                                    "1 " ++ String.toUpper m.target ++ " image"

                                else
                                    "1 ZIP containing " ++ plural count (String.toUpper m.target ++ " image") (String.toUpper m.target ++ " images")
                               )
                            ++ " · "
                            ++ dpi
                            ++ " DPI"
                    )
                |> Maybe.withDefault "Choose a valid page range to see your output."

        Split ->
            selected
                |> Maybe.map
                    (\count ->
                        plural count "selected page" "selected pages"
                            ++ " → "
                            ++ (case m.outputMode of
                                    "combined" ->
                                        "1 PDF"

                                    "chunks" ->
                                        V.whole 1 1000 m.chunk
                                            |> Result.toMaybe
                                            |> Maybe.map (\chunk -> "1 ZIP containing " ++ plural ((count + chunk - 1) // chunk) "PDF" "PDFs" ++ " · up to " ++ plural chunk "page per PDF" "pages per PDF")
                                            |> Maybe.withDefault "enter a valid group size."

                                    _ ->
                                        "1 ZIP containing " ++ plural count "single-page PDF" "single-page PDFs"
                               )
                    )
                |> Maybe.withDefault "Choose a valid page range to see your output."

        Merge ->
            plural (List.length m.files) "PDF" "PDFs" ++ " → 1 PDF · " ++ plural pages "page" "pages" ++ " in your chosen order"

        ImagePdf ->
            plural (List.length m.files) "image" "images" ++ " → 1 PDF · one image per page at 300 DPI"

        YardSign ->
            if validYardSettings m then
                let
                    ( w, h ) =
                        yardDimensions m
                in
                w ++ " × " ++ h ++ " in finished · ¼ in bleed on every edge · 1 PDF"

            else
                "Correct the sign settings before downloading."

        Impose ->
            imposed m


imposed : Model -> String
imposed m =
    if Dict.keys m.drafts |> List.any (String.startsWith "invalid:") then
        "Correct the highlighted setup fields before downloading."

    else if Dict.values m.quantityDrafts |> List.any (\draft -> Result.toMaybe (V.whole 0 10000 draft) == Nothing) then
        "Correct the copy quantities before downloading."

    else
        imposedLayout m


imposedLayout : Model -> String
imposedLayout m =
    case m.layout of
        Just layout ->
            if m.layoutReady then
                "1 PDF · "
                    ++ plural layout.sheetsRequired "print sheet" "print sheets"
                    ++ (if layout.duplex /= Nothing then
                            " · double-sided"

                        else
                            " · single-sided"
                       )
                    ++ " · "
                    ++ String.fromFloat layout.parentSheetSize.width
                    ++ " × "
                    ++ String.fromFloat layout.parentSheetSize.height
                    ++ " in"

            else
                "Updating print layout… Download is available when the layout is ready."

        Nothing ->
            "Complete the print setup to prepare your PDF."
