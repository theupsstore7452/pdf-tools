module Model exposing (..)

import Api.Generated as A
import Bytes exposing (Bytes)
import Da.Dropdown as Dropdown
import Da.Reorderable as Reorderable
import Dict exposing (Dict)
import File exposing (File)
import Http
import Json.Decode as D
import Time


type Operation
    = PdfImage
    | Split
    | Merge
    | ImagePdf
    | Impose
    | YardSign


type Connector
    = NotChecked
    | Checking
    | Available
    | Unavailable String


type YardDestination
    = Download
    | VersaWorks


type alias Selected =
    { id : Int, file : File, pages : Int }


type alias Display =
    { layout : A.LayoutResult, urls : Dict Int String, sheet : Int, back : Bool, source : String }


type alias Toast =
    { id : Int, message : String, kind : String }


type alias YardProof =
    { session : Int, source : Maybe String, page : Int, token : Int, url : String, error : String }


emptyYardProof : YardProof
emptyYardProof =
    { session = 0, source = Nothing, page = 1, token = 0, url = "", error = "" }


type alias Model =
    { files : List Selected
    , attempted : List Selected
    , pending : List Selected
    , nextId : Int
    , operation : Operation
    , yardProof : YardProof
    , yardPreset : Maybe ( Int, Int )
    , yardWidth : String
    , yardHeight : String
    , yardMode : String
    , connector : Connector
    , connectorToken : Int
    , delivery : String
    , sending : Bool
    , preferredTool : Maybe Operation
    , busy : Bool
    , phase : String
    , progress : Int
    , error : String
    , notice : String
    , toast : Maybe Toast
    , nextToastId : Int
    , epoch : Int
    , job : Maybe String
    , jobKind : String
    , retryKind : String
    , target : String
    , quality : String
    , imagePages : String
    , extractPages : String
    , outputMode : String
    , chunk : String
    , request : A.LayoutRequest
    , pageOrder : List Int
    , pageDraft : List Int
    , pageOrganizer : Bool
    , pageSource : Maybe String
    , pageSourceOwned : Bool
    , pageSourceOrder : List Int
    , pageThumbnails : Dict Int String
    , pageBatch : Int
    , pageSelected : Int
    , pagePosition : String
    , pageToken : Int
    , pageLoading : Bool
    , pageError : String
    , pageOrderState : Reorderable.State
    , sizeInput : Maybe A.SizeInches
    , sizeNotice : String
    , source : Maybe A.PreparedSourceResponse
    , revision : Int
    , layout : Maybe A.LayoutResult
    , layoutReady : Bool
    , display : Maybe Display
    , previewToken : Int
    , previewLoading : Bool
    , previewError : String
    , previewZoom : Int
    , previewGuides : Bool
    , sheet : Int
    , back : Bool
    , step : Int
    , rail : String
    , chosenWidth : Bool
    , chosenHeight : Bool
    , autoFinishedSize : Bool
    , drafts : Dict String String
    , quantityDrafts : Dict Int String
    , repeatSingle : List Int
    , repeatDouble : List Int
    , selectedPage : Int
    , selectedImpression : Maybe Int
    , artworkMenu : Maybe Int
    , perArtwork : Bool
    , theme : String
    , dialog : String
    , rangeDraft : String
    , bulkDraft : String
    , savedName : String
    , editingPreset : Maybe String
    , presets : List A.GangUpPreset
    , recent : List A.RecentGangUpJob
    , fileOrder : Reorderable.State
    , workspaceMenu : Bool
    , presetsOpen : Bool
    , dropdowns : Dict String Dropdown.State
    }


type Msg
    = Uploaded Http.Progress
    | Discarded String (Result Http.Error A.PreparedSourceResponse)
    | OpenPages
    | ClosePages
    | ApplyPageOrder
    | PageBatch Int
    | PageCommand String
    | PageSelected Int
    | PagePosition String
    | MovePage
    | PageOrderChanged Reorderable.Change
    | YardSource Int (Result Http.Error String)
    | YardPage Int
    | RetryYardProof
    | WorkspacePrepared Int (Result Http.Error ( String, Int ))
    | OrderedSource Int (Result Http.Error A.PreparedSourceResponse)
    | WorkspaceDiscarded String (Result Http.Error String)
    | Browse Bool
    | Picked Bool File (List File)
    | Dropped (List File)
    | Inspected Int Int (Result Http.Error Int)
    | Remove Int
    | Reordered Reorderable.Change
    | SetWorkspaceMenu Bool
    | SetPresetsOpen Bool
    | WorkspaceAction String
    | Switch Operation
    | ChooseTool Operation
    | Field String String
    | DropdownChanged String String Dropdown.Change
    | Quantity Int String
    | CropAnchor Float Float
    | RotateArtwork Int Int
    | RotateAllArtwork Int
    | SelectImpression Int Int
    | SetStep Int
    | SetRail String
    | Toggle String
    | OpenDialog String
    | CloseDialog
    | ApplyDialog
    | Clear
    | Cancel
    | Retry
    | RetryPreview
    | Submit
    | CheckConnector
    | ConnectorStatus Int (Result Http.Error Bool)
    | SendYard
    | YardSent Int (Result Http.Error String)
    | YardExported Int YardDestination String (Result Http.Error Bytes)
    | Created Int String (Result Http.Error String)
    | Poll Int String
    | Polled Int String (Result Http.Error String)
    | Prepared Int (Result Http.Error A.PreparedSourceResponse)
    | LayoutDue Int
    | LaidOut Int (Result Http.Error A.LayoutResult)
    | BrowserEvent D.Value
    | Navigate Int Bool
    | SetPreviewZoom Int
    | FitPreview
    | TogglePreviewGuides
    | Lease Time.Posix
    | Catalog String (Result Http.Error D.Value)
    | ApplyPreset String
    | ApplySaved String String
    | Save String
    | DeleteSaved String String
    | Saved String (Result Http.Error D.Value)
    | DismissToast Int
    | NoOp


operationLabel : Operation -> String
operationLabel op =
    case op of
        PdfImage ->
            "PDF to images"

        Split ->
            "Extract pages"

        Merge ->
            "Combine PDFs"

        ImagePdf ->
            "Images to PDF"

        YardSign ->
            "Yard Signs"

        Impose ->
            "Impose artwork"


isPdf : File -> Bool
isPdf f =
    String.endsWith ".pdf" (String.toLower (File.name f)) || File.mime f == "application/pdf"


isImage : File -> Bool
isImage f =
    List.member (File.mime f) [ "image/png", "image/jpeg" ] || List.any (\suffix -> String.endsWith suffix (String.toLower (File.name f))) [ ".png", ".jpg", ".jpeg" ]


operations : List Selected -> List Operation
operations files =
    if List.all (.file >> isPdf) files then
        if List.length files > 1 then
            [ Merge, PdfImage, Impose ]

        else
            [ PdfImage, Split, Impose, YardSign ]

    else if List.all (.file >> isImage) files then
        [ ImagePdf, Impose ]

    else
        [ Impose ]


validYardDimension : String -> Bool
validYardDimension draft =
    String.toFloat draft |> Maybe.map (\n -> n > 0 && n <= 199.5) |> Maybe.withDefault False


yardPresets : List ( Int, Int )
yardPresets =
    [ ( 18, 24 ), ( 24, 18 ), ( 24, 36 ), ( 36, 24 ) ]


yardPresetKey : ( Int, Int ) -> String
yardPresetKey ( w, h ) =
    String.fromInt w ++ "x" ++ String.fromInt h


yardDimensions : Model -> ( String, String )
yardDimensions m =
    case m.yardPreset of
        Just ( w, h ) ->
            ( String.fromInt w, String.fromInt h )

        Nothing ->
            ( m.yardWidth, m.yardHeight )


validYardSettings : Model -> Bool
validYardSettings m =
    let
        ( w, h ) =
            yardDimensions m
    in
    validYardDimension w && validYardDimension h && List.member m.yardMode [ "fit", "fill", "stretch" ]


canSendYard : Model -> Bool
canSendYard m =
    case m.files of
        [ selected ] ->
            m.operation == YardSign && m.connector == Available && not m.busy && isPdf selected.file && validYardSettings m

        _ ->
            False
