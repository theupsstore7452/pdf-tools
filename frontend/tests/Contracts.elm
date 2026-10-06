module Contracts exposing (tests)

import Api.Generated as A
import Expect
import Json.Decode as D
import Json.Encode as E
import RustWire
import Test exposing (..)


roundTrip : D.Decoder a -> (a -> E.Value) -> String -> Result D.Error E.Value
roundTrip decoder encoder raw =
    D.decodeString decoder raw |> Result.map encoder


codec : String -> String -> Result D.Error E.Value
codec name raw =
    case name of
        "Orientation" ->
            roundTrip A.orientationDecoder A.orientationEncoder raw

        "OrientationPreference" ->
            roundTrip A.orientationPreferenceDecoder A.orientationPreferenceEncoder raw

        "FinishedSizeMode" ->
            roundTrip A.finishedSizeModeDecoder A.finishedSizeModeEncoder raw

        "ArtworkFitMode" ->
            roundTrip A.artworkFitModeDecoder A.artworkFitModeEncoder raw

        "Sides" ->
            roundTrip A.sidesDecoder A.sidesEncoder raw

        "LayoutMode" ->
            roundTrip A.layoutModeDecoder A.layoutModeEncoder raw

        "BleedOption" ->
            roundTrip A.bleedOptionDecoder A.bleedOptionEncoder raw

        "BleedSource" ->
            roundTrip A.bleedSourceDecoder A.bleedSourceEncoder raw

        "ImpositionMode" ->
            roundTrip A.impositionModeDecoder A.impositionModeEncoder raw

        "DuplexFlipEdge" ->
            roundTrip A.duplexFlipEdgeDecoder A.duplexFlipEdgeEncoder raw

        "GangUpExportType" ->
            roundTrip A.gangUpExportTypeDecoder A.gangUpExportTypeEncoder raw

        "OutputPreference" ->
            roundTrip A.outputPreferenceDecoder A.outputPreferenceEncoder raw

        "LayoutRequest" ->
            roundTrip A.layoutRequestDecoder A.layoutRequestEncoder raw

        "LayoutResult" ->
            roundTrip A.layoutResultDecoder A.layoutResultEncoder raw

        "ArtworkFit" ->
            roundTrip A.artworkFitDecoder A.artworkFitEncoder raw

        "PageOverride" ->
            roundTrip A.pageOverrideDecoder A.pageOverrideEncoder raw

        "DuplexSettings" ->
            roundTrip A.duplexSettingsDecoder A.duplexSettingsEncoder raw

        "PresetInput" ->
            roundTrip A.presetInputDecoder A.presetInputEncoder raw

        "GangUpPreset" ->
            roundTrip A.gangUpPresetDecoder A.gangUpPresetEncoder raw

        "RecentGangUpJob" ->
            roundTrip A.recentGangUpJobDecoder A.recentGangUpJobEncoder raw

        "GangUpExportRecord" ->
            roundTrip A.gangUpExportRecordDecoder A.gangUpExportRecordEncoder raw

        "PdfAnalysis" ->
            roundTrip A.pdfAnalysisDecoder A.pdfAnalysisEncoder raw

        "PreparedSourceResponse" ->
            roundTrip A.preparedSourceResponseDecoder A.preparedSourceResponseEncoder raw

        "PreviewBatchRequest" ->
            roundTrip A.previewBatchRequestDecoder A.previewBatchRequestEncoder raw

        _ ->
            Err (D.Failure "Unregistered contract codec" E.null)


normal : D.Decoder E.Value
normal =
    D.oneOf
        [ D.map (List.filter (\( key, _ ) -> key /= "backAlignment") >> List.sortBy Tuple.first >> E.object) (D.keyValuePairs (D.lazy (\_ -> normal)))
        , D.map (E.list identity) (D.list (D.lazy (\_ -> normal)))
        , D.map E.string D.string
        , D.map E.float D.float
        , D.map E.bool D.bool
        , D.null E.null
        ]


canonical : String -> Result D.Error String
canonical raw =
    D.decodeString normal raw |> Result.map (E.encode 0)


tests : Test
tests =
    describe "Generated codecs against production Rust Serde"
        (List.indexedMap
            (\i ( name, raw ) ->
                test (name ++ " fixture " ++ String.fromInt i)
                    (\_ ->
                        case codec name raw of
                            Err err ->
                                Expect.fail (D.errorToString err)

                            Ok encoded ->
                                Expect.equal (canonical raw) (canonical (E.encode 0 encoded))
                    )
            )
            RustWire.cases
            ++ [ test "backAlignment is decoded response metadata and omitted from requests"
                    (\_ ->
                        roundTrip A.duplexSettingsDecoder A.duplexSettingsEncoder "{\"flipEdge\":\"shortEdge\",\"rotateBack180\":true,\"backAlignment\":\"derived by Rust\"}"
                            |> Result.map (D.decodeValue (D.field "backAlignment" D.string) >> Result.toMaybe)
                            |> Expect.equal (Ok Nothing)
                    )
               , test "Unknown enum values fail instead of silently selecting another mode"
                    (\_ ->
                        D.decodeString A.artworkFitModeDecoder "\"futureFit\"" |> Result.toMaybe |> Expect.equal Nothing
                    )
               ]
        )
