module Imposition exposing (applyPreset, bindSource, detectedFinishedSize, initial, pageNumber, pagesForSheet, quantities, setMode, setSides, summary)

import Api.Generated as A


initial : A.LayoutRequest
initial =
    { sourceId = Nothing
    , sourcePages = []
    , finishedSizeMode = A.FinishedSizeModeCommon
    , artworkFit = Just { mode = A.ArtworkFitModeContain, position = { x = 0.5, y = 0.5 } }
    , pageOverrides = []
    , sourcePdfSize = { width = 3.5, height = 2 }
    , sourceTrimBox = Nothing
    , sourcePageCount = Nothing
    , finishedCutSize = { width = 3.5, height = 2 }
    , parentSheetSize = { width = 12, height = 18 }
    , quantityRequested = 1
    , impositionMode = A.ImpositionModeUnique
    , impressionQuantities = Nothing
    , orientationPreference = A.OrientationPreferenceAuto
    , sides = A.SidesSingle
    , duplex = Nothing
    , layoutMode = A.LayoutModeMaxPieces
    , bleedOption = A.BleedOptionUseAsIs
    , sourceBleedOverride = Nothing
    , createdBleedAmount = 0.125
    , gutter = { horizontal = 0.299, vertical = 0.299 }
    , manual = Nothing
    }


detectedFinishedSize : A.PdfAnalysis -> A.SizeInches
detectedFinishedSize analysis =
    case analysis.trimBox of
        Just trim ->
            { width = trim.width, height = trim.height }

        Nothing ->
            if List.head analysis.sourcePages |> Maybe.map .physicalSizeAssumed |> Maybe.withDefault False then
                analysis.sourcePdfSize

            else
                Maybe.withDefault analysis.sourcePdfSize analysis.suggestedFinishedCutSize


bindSource : A.PreparedSourceResponse -> A.LayoutRequest -> A.LayoutRequest
bindSource source r =
    let
        a =
            source.analysis

        next =
            { r | sourceId = Just source.sourceId, sourcePages = [], sourcePdfSize = a.sourcePdfSize, sourceTrimBox = a.trimBox, sourcePageCount = Just a.pageCount, pageOverrides = List.filter (\p -> p.pageNumber <= a.pageCount) r.pageOverrides }
    in
    setSides
        (if modBy 2 a.pageCount == 0 then
            r.sides

         else
            A.SidesSingle
        )
        next


quantities : A.LayoutRequest -> List Int
quantities r =
    let
        count =
            Maybe.withDefault 1 r.sourcePageCount
                // (if r.sides == A.SidesDouble then
                        2

                    else
                        1
                   )
    in
    Maybe.withDefault (List.repeat count 1) r.impressionQuantities |> List.take count |> (\xs -> xs ++ List.repeat (max 0 (count - List.length xs)) 1)


setSides : A.Sides -> A.LayoutRequest -> A.LayoutRequest
setSides sides r =
    let
        next =
            { r
                | sides = sides
                , duplex =
                    if sides == A.SidesDouble then
                        Just (Maybe.withDefault { flipEdge = A.DuplexFlipEdgeLongEdge, rotateBack180 = False, backAlignment = "" } r.duplex)

                    else
                        Nothing
            }

        qs =
            quantities next
    in
    { next
        | impressionQuantities =
            if r.impositionMode == A.ImpositionModeRepeat then
                Just qs

            else
                Nothing
        , quantityRequested =
            if r.impositionMode == A.ImpositionModeRepeat then
                List.sum qs

            else
                Maybe.withDefault 1 r.sourcePageCount
                    // (if sides == A.SidesDouble then
                            2

                        else
                            1
                       )
    }


setMode : A.ImpositionMode -> A.LayoutRequest -> A.LayoutRequest
setMode mode r =
    setSides r.sides { r | impositionMode = mode }


applyPreset : A.GangUpPreset -> A.LayoutRequest -> A.LayoutRequest
applyPreset p r =
    { r
        | finishedCutSize = p.finishedCutSize
        , finishedSizeMode = p.finishedSizeMode
        , parentSheetSize = p.parentSheetSize
        , artworkFit = p.artworkFit
        , sourceBleedOverride = p.sourceBleedOverride
        , bleedOption = p.bleedHandling
        , createdBleedAmount = p.createdBleedAmount
        , gutter = p.gutter
        , orientationPreference = p.orientationPreference
        , layoutMode = p.layoutPreference
        , manual = p.manual
    }


summary : A.LayoutResult -> A.RecentGangUpLayoutSummary
summary l =
    { piecesPerSheet = l.piecesPerSheet, sheetsRequired = l.sheetsRequired, totalPiecesProduced = l.totalPiecesProduced, extraPiecesProduced = l.extraPiecesProduced }


pageNumber : A.LayoutResult -> Int -> Bool -> Int -> Maybe Int
pageNumber l sheet back index =
    let
        impression =
            sheet * l.piecesPerSheet + index

        repeated offset qs =
            case qs of
                [] ->
                    Nothing

                q :: rest ->
                    if offset < q then
                        Just 0

                    else
                        Maybe.map ((+) 1) (repeated (offset - q) rest)

        source =
            if l.impositionMode == A.ImpositionModeRepeat then
                repeated impression (Maybe.withDefault [ l.quantityRequested ] l.impressionQuantities)

            else
                Just impression
    in
    if impression >= l.impressionsRequested then
        Nothing

    else
        Maybe.map
            (\n ->
                if l.duplex /= Nothing then
                    n
                        * 2
                        + (if back then
                            2

                           else
                            1
                          )

                else
                    n + 1
            )
            source


pagesForSheet : A.LayoutResult -> Int -> Bool -> List Int
pagesForSheet l sheet back =
    List.filterMap (pageNumber l sheet back) (List.range 0 (l.piecesPerSheet - 1))
        |> List.foldl
            (\n xs ->
                if List.member n xs then
                    xs

                else
                    xs ++ [ n ]
            )
            []
