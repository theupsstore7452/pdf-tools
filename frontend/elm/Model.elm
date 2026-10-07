module Model exposing (..)

import Api.Generated as A
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


type alias Selected =
    { id : Int, file : File, pages : Int }


type alias Display =
    { layout : A.LayoutResult, urls : Dict Int String, sheet : Int, back : Bool, source : String }


type alias Model =
    { files : List Selected
    , attempted : List Selected
    , pending : List Selected
    , nextId : Int
    , operation : Operation
    , busy : Bool
    , phase : String
    , progress : Int
    , error : String
    , notice : String
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
    , source : Maybe A.PreparedSourceResponse
    , revision : Int
    , layout : Maybe A.LayoutResult
    , layoutReady : Bool
    , display : Maybe Display
    , previewToken : Int
    , previewLoading : Bool
    , previewError : String
    , sheet : Int
    , back : Bool
    , step : Int
    , rail : String
    , collapsed : Bool
    , chosenWidth : Bool
    , chosenHeight : Bool
    , drafts : Dict String String
    , quantityDrafts : Dict Int String
    , repeatSingle : List Int
    , repeatDouble : List Int
    , selectedPage : Int
    , perArtwork : Bool
    , showCut : Bool
    , showBleed : Bool
    , showGutters : Bool
    , showPaths : Bool
    , zoom : Float
    , theme : String
    , dialog : String
    , rangeDraft : String
    , bulkDraft : String
    , savedName : String
    , editingPreset : Maybe String
    , presets : List A.GangUpPreset
    , recent : List A.RecentGangUpJob
    , history : List A.GangUpExportRecord
    , dragId : Maybe Int
    }


type Msg
    = Uploaded Http.Progress
    | Discarded String (Result Http.Error A.PreparedSourceResponse)
    | Browse Bool
    | Picked Bool File (List File)
    | Dropped (List File)
    | Inspected Int Int (Result Http.Error Int)
    | Remove Int
    | Move Int Int
    | Drag Int
    | DropOn Int
    | Switch Operation
    | Field String String
    | Quantity Int String
    | CropAnchor Float Float
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
    | Created Int String (Result Http.Error String)
    | Poll Int String
    | Polled Int String (Result Http.Error String)
    | Prepared Int (Result Http.Error A.PreparedSourceResponse)
    | LayoutDue Int
    | LaidOut Int (Result Http.Error A.LayoutResult)
    | BrowserEvent D.Value
    | Navigate Int Bool
    | Lease Time.Posix
    | Catalog String (Result Http.Error D.Value)
    | ApplyPreset String
    | ApplySaved String String
    | Save String
    | DeleteSaved String String
    | Saved String (Result Http.Error D.Value)
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
            [ PdfImage, Split, Impose ]

    else if List.all (.file >> isImage) files then
        [ ImagePdf, Impose ]

    else
        [ Impose ]
