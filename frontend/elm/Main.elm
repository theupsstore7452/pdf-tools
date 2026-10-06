port module Main exposing (init, main, update, validSetup)

import Api.Generated as A
import Browser
import Dict
import File
import File.Download
import File.Select
import Http
import Imposition as I
import Job
import Json.Decode as D
import Json.Encode as E
import Model exposing (..)
import Process
import Task
import Time
import Validation as V
import View


port resources : E.Value -> Cmd msg


port browserEvents : (D.Value -> msg) -> Sub msg


main : Program String Model Msg
main =
    Browser.element { init = init, update = update, view = View.view, subscriptions = subscriptions }


init : String -> ( Model, Cmd Msg )
init theme =
    ( { files = []
      , attempted = []
      , pending = []
      , nextId = 1
      , operation = PdfImage
      , busy = False
      , phase = ""
      , progress = 0
      , error = ""
      , notice = ""
      , epoch = 0
      , job = Nothing
      , jobKind = ""
      , retryKind = ""
      , target = "png"
      , quality = "screen"
      , imagePages = "all"
      , extractPages = "all"
      , outputMode = "individual"
      , chunk = "10"
      , request = I.initial
      , source = Nothing
      , revision = 0
      , layout = Nothing
      , layoutReady = False
      , display = Nothing
      , previewToken = 0
      , previewLoading = False
      , previewError = ""
      , sheet = 0
      , back = False
      , step = 0
      , reached = 0
      , rail = "setup"
      , collapsed = False
      , chosenWidth = False
      , chosenHeight = False
      , drafts = Dict.empty
      , quantityDrafts = Dict.empty
      , repeatSingle = []
      , repeatDouble = []
      , selectedPage = 1
      , perArtwork = False
      , showCut = True
      , showBleed = True
      , showGutters = False
      , showPaths = False
      , zoom = 1
      , theme = theme
      , dialog = ""
      , rangeDraft = "1"
      , bulkDraft = "1"
      , savedName = ""
      , editingPreset = Nothing
      , presets = []
      , recent = []
      , history = []
      , dragId = Nothing
      }
    , Cmd.batch (List.map catalog [ "presets", "recent-jobs", "export-history" ])
    )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch [ browserEvents BrowserEvent, Time.every (10 * 60 * 1000) Lease, Http.track "job-upload" Uploaded ]


bridge : String -> List ( String, E.Value ) -> Cmd Msg
bridge action args =
    resources (E.object (( "action", E.string action ) :: args))


httpError : Http.Error -> String
httpError error =
    case error of
        Http.BadUrl _ ->
            "The request URL is invalid."

        Http.Timeout ->
            "The server took too long. Your files and settings are retained. Retry."

        Http.NetworkError ->
            "Could not reach the server. Check your connection and retry."

        Http.BadStatus code ->
            "The server rejected the request (" ++ String.fromInt code ++ ")."

        Http.BadBody detail ->
            detail


expect : (Result Http.Error a -> Msg) -> (String -> Result String a) -> Http.Expect Msg
expect tag parse =
    Http.expectStringResponse tag
        (\response ->
            case response of
                Http.BadUrl_ url ->
                    Err (Http.BadUrl url)

                Http.Timeout_ ->
                    Err Http.Timeout

                Http.NetworkError_ ->
                    Err Http.NetworkError

                Http.BadStatus_ metadata body ->
                    Err
                        (Http.BadBody
                            (if String.isEmpty body then
                                "Server returned HTTP " ++ String.fromInt metadata.statusCode ++ ". Retry the request."

                             else
                                body
                            )
                        )

                Http.GoodStatus_ _ body ->
                    Result.mapError Http.BadBody (parse body)
        )


jsonExpect : (Result Http.Error a -> Msg) -> D.Decoder a -> Http.Expect Msg
jsonExpect tag decoder =
    expect tag (D.decodeString decoder >> Result.mapError D.errorToString)


request : String -> String -> Http.Body -> Http.Expect Msg -> Maybe String -> Cmd Msg
request method url body response tracker =
    Http.request { method = method, headers = [], url = url, body = body, expect = response, timeout = Just 120000, tracker = tracker }


delete : String -> Cmd Msg
delete url =
    request "DELETE" url Http.emptyBody (expect (\_ -> NoOp) Ok) Nothing


catalog : String -> Cmd Msg
catalog name =
    Http.get { url = "gang-up/" ++ name, expect = jsonExpect (Catalog name) D.value }


inspectNext : Model -> Cmd Msg
inspectNext m =
    case List.filter (\f -> isPdf f.file && f.pages == 0) m.pending |> List.head of
        Just f ->
            request "POST" "pdf/inspect" (Http.multipartBody [ Http.filePart "file" f.file ]) (jsonExpect (Inspected m.epoch f.id) (D.field "pageCount" D.int)) (Just "inspection")

        Nothing ->
            Cmd.none


intake : Bool -> List File.File -> Model -> ( Model, Cmd Msg )
intake append files m =
    if m.busy || List.isEmpty files then
        ( m, Cmd.none )

    else if List.any (\f -> not (isPdf f || isImage f)) files then
        ( { m | error = "Choose PDF, PNG, or JPEG files." }, Cmd.none )

    else
        let
            selected =
                (if append then
                    m.files

                 else
                    []
                )
                    ++ List.indexedMap (\i f -> { id = m.nextId + i, file = f, pages = 0 }) files

            next =
                { m | pending = selected, attempted = selected, nextId = m.nextId + List.length files, epoch = m.epoch + 1, busy = True, progress = 0, error = "", notice = "", phase = "Checking PDFs", retryKind = "inspection", job = Nothing }
        in
        if List.any (\f -> isPdf f.file && f.pages == 0) selected then
            ( next, inspectNext next )

        else
            commitFiles next


commitFiles : Model -> ( Model, Cmd Msg )
commitFiles m =
    let
        available =
            operations m.pending

        op =
            if not (List.isEmpty m.files) && List.member m.operation available then
                m.operation

            else
                Maybe.withDefault Impose (List.head available)

        next =
            { m | files = m.pending, pending = [], busy = False, phase = "", error = "", operation = op }
    in
    if op == Impose then
        prepare
            { next
                | files =
                    if List.isEmpty m.files then
                        m.pending

                    else
                        m.files
                , pending = m.pending
            }

    else
        ( { next | source = Nothing, display = Nothing, layout = Nothing, layoutReady = False }
        , Cmd.batch [ Maybe.map (.sourceId >> (\id -> delete ("gang-up/sources/" ++ id))) m.source |> Maybe.withDefault Cmd.none, bridge "clearPreviews" [] ]
        )


prepare : Model -> ( Model, Cmd Msg )
prepare m =
    let
        next =
            { m | epoch = m.epoch + 1, busy = True, phase = "Preparing artwork", progress = 0, jobKind = "prepare", retryKind = "prepare", error = "", job = Nothing, layoutReady = False }
    in
    ( next
    , request "POST"
        "gang-up/sources"
        (Http.multipartBody
            (List.map (\f -> Http.filePart "file" f.file)
                (if List.isEmpty m.pending then
                    m.files

                 else
                    m.pending
                )
            )
        )
        (expect (Created next.epoch "prepare") Ok)
        (Just "job-upload")
    )


schedule : Model -> ( Model, Cmd Msg )
schedule m =
    let
        next =
            { m | revision = m.revision + 1, layoutReady = False, error = "", previewError = "", previewLoading = False, previewToken = m.previewToken + 1 }
    in
    ( next, Cmd.batch [ Http.cancel "layout", bridge "cancelPreview" [], Process.sleep 180 |> Task.perform (\_ -> LayoutDue next.revision) ] )


preview : Model -> ( Model, Cmd Msg )
preview m =
    case ( m.source, m.layout ) of
        ( Just source, Just layout ) ->
            let
                token =
                    m.previewToken + 1

                pages =
                    I.pagesForSheet layout m.sheet m.back
                        |> (\xs ->
                                if List.member m.selectedPage xs then
                                    xs

                                else
                                    xs ++ [ m.selectedPage ]
                           )
            in
            ( { m | previewToken = token, previewLoading = True, previewError = "" }
            , bridge "preview" [ ( "token", E.int token ), ( "source", E.string source.sourceId ), ( "pages", E.list E.int pages ), ( "bleed", Maybe.map E.float layout.sourceBleedOverride |> Maybe.withDefault E.null ) ]
            )

        _ ->
            ( m, Cmd.none )


validSetup : Model -> Bool
validSetup m =
    m.chosenWidth && m.chosenHeight && Dict.isEmpty (Dict.filter (\k value -> String.startsWith "invalid:" k && value /= "") m.drafts) && Dict.isEmpty (Dict.filter (\_ s -> Result.toMaybe (V.whole 0 10000 s) == Nothing) m.quantityDrafts) && m.request.quantityRequested > 0 && m.request.quantityRequested <= 10000


setNumber : String -> String -> Model -> ( Model, Cmd Msg )
setNumber key draft m =
    let
        wholeKeys =
            [ "rows", "columns", "copies" ]

        low =
            if List.member key [ "copies", "crop-x", "crop-y" ] || String.startsWith "margin-" key || String.startsWith "gutter-" key then
                0

            else if key == "rows" || key == "columns" then
                1

            else if String.startsWith "finished-" key || String.startsWith "artwork-" key || String.startsWith "sheet-" key then
                0.01

            else
                0.001

        high =
            if key == "copies" then
                10000

            else if List.member key [ "crop-x", "crop-y", "source-bleed", "created-bleed" ] then
                1

            else
                100

        parsed =
            if List.member key wholeKeys then
                V.whole (round low) (round high) draft |> Result.map toFloat

            else
                V.number low high draft

        drafts =
            Dict.insert key draft m.drafts

        r =
            m.request

        cut =
            r.finishedCutSize

        sheet =
            r.parentSheetSize

        gutter =
            r.gutter

        manual =
            Maybe.withDefault { rows = 1, columns = 1, rotationDegrees = 0, margins = Nothing } r.manual

        fit =
            effectiveFit m

        pos =
            fit.position

        change n =
            case key of
                "finished-width" ->
                    { r | finishedCutSize = { cut | width = n }, finishedSizeMode = A.FinishedSizeModeCommon }

                "finished-height" ->
                    { r | finishedCutSize = { cut | height = n }, finishedSizeMode = A.FinishedSizeModeCommon }

                "artwork-width" ->
                    overrideSize m { width = n, height = (effectiveSize m).height }

                "artwork-height" ->
                    overrideSize m { width = (effectiveSize m).width, height = n }

                "sheet-width" ->
                    { r | parentSheetSize = { sheet | width = n } }

                "sheet-height" ->
                    { r | parentSheetSize = { sheet | height = n } }

                "gutter-horizontal" ->
                    { r | gutter = { gutter | horizontal = n } }

                "gutter-vertical" ->
                    { r | gutter = { gutter | vertical = n } }

                "created-bleed" ->
                    { r | createdBleedAmount = n }

                "source-bleed" ->
                    { r | sourceBleedOverride = Just n }

                "rows" ->
                    { r | manual = Just { manual | rows = round n } }

                "columns" ->
                    { r | manual = Just { manual | columns = round n } }

                "copies" ->
                    withQuantities (List.repeat (List.length (I.quantities r)) (round n)) r

                "crop-x" ->
                    overrideFit m { fit | position = { pos | x = n } }

                "crop-y" ->
                    overrideFit m { fit | position = { pos | y = n } }

                _ ->
                    let
                        margins =
                            Maybe.withDefault { top = 0, right = 0, bottom = 0, left = 0 } manual.margins

                        nextMargins =
                            case key of
                                "margin-top" ->
                                    { margins | top = n }

                                "margin-right" ->
                                    { margins | right = n }

                                "margin-bottom" ->
                                    { margins | bottom = n }

                                _ ->
                                    { margins | left = n }
                    in
                    { r | manual = Just { manual | margins = Just nextMargins } }
    in
    case parsed of
        Err issue ->
            ( { m | drafts = Dict.insert ("invalid:" ++ key) issue drafts, revision = m.revision + 1, previewToken = m.previewToken + 1, previewLoading = False, layoutReady = False }, Cmd.batch [ Http.cancel "layout", bridge "cancelPreview" [] ] )

        Ok n ->
            schedule { m | request = change n, drafts = Dict.remove ("invalid:" ++ key) drafts, chosenWidth = m.chosenWidth || key == "finished-width", chosenHeight = m.chosenHeight || key == "finished-height" }


withQuantities : List Int -> A.LayoutRequest -> A.LayoutRequest
withQuantities qs r =
    { r | impressionQuantities = Just qs, quantityRequested = List.sum qs }


effectiveFit : Model -> A.ArtworkFit
effectiveFit m =
    List.filter (\p -> p.pageNumber == m.selectedPage) m.request.pageOverrides
        |> List.head
        |> Maybe.andThen .artworkFit
        |> (\own ->
                if m.perArtwork then
                    own

                else
                    Nothing
           )
        |> (\own ->
                case own of
                    Just fit ->
                        fit

                    Nothing ->
                        Maybe.withDefault { mode = A.ArtworkFitModeContain, position = { x = 0.5, y = 0.5 } } m.request.artworkFit
           )


effectiveSize : Model -> A.SizeInches
effectiveSize m =
    if m.perArtwork then
        List.filter (\p -> p.pageNumber == m.selectedPage) m.request.pageOverrides |> List.head |> Maybe.andThen .finishedCutSize |> Maybe.withDefault m.request.finishedCutSize

    else
        m.request.finishedCutSize


updateOverride : Model -> (A.PageOverride -> A.PageOverride) -> A.LayoutRequest
updateOverride m change =
    let
        r =
            m.request

        old =
            List.filter (\p -> p.pageNumber == m.selectedPage) r.pageOverrides |> List.head |> Maybe.withDefault { pageNumber = m.selectedPage, finishedCutSize = Nothing, artworkFit = Nothing }
    in
    { r | pageOverrides = List.filter (\p -> p.pageNumber /= m.selectedPage) r.pageOverrides ++ [ change old ] }


overrideSize : Model -> A.SizeInches -> A.LayoutRequest
overrideSize m size =
    updateOverride m (\p -> { p | finishedCutSize = Just size })


overrideFit : Model -> A.ArtworkFit -> A.LayoutRequest
overrideFit m fit =
    if m.perArtwork then
        updateOverride m (\p -> { p | artworkFit = Just fit })

    else
        let
            r =
                m.request
        in
        { r | artworkFit = Just fit }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg m =
    let
        ( next, cmd ) =
            updateInternal msg m
    in
    ( next
    , if next.epoch /= m.epoch then
        Cmd.batch [ bridge "identity" [ ( "token", E.int next.epoch ) ], cmd ]

      else
        cmd
    )


updateInternal : Msg -> Model -> ( Model, Cmd Msg )
updateInternal msg m =
    case msg of
        Uploaded progress ->
            if m.busy then
                case progress of
                    Http.Sending info ->
                        ( { m | progress = min 20 (round (20 * toFloat info.sent / toFloat (max 1 info.size))) }, Cmd.none )

                    _ ->
                        ( m, Cmd.none )

            else
                ( m, Cmd.none )

        Discarded id result ->
            ( m, Cmd.batch [ delete ("jobs/" ++ id), Result.toMaybe result |> Maybe.map (.sourceId >> (\sourceId -> delete ("gang-up/sources/" ++ sourceId))) |> Maybe.withDefault Cmd.none ] )

        NoOp ->
            ( m, Cmd.none )

        Browse append ->
            ( m, File.Select.files [ "application/pdf", "image/png", "image/jpeg" ] (Picked append) )

        Picked append first rest ->
            intake append (first :: rest) m

        Dropped files ->
            intake (not (List.isEmpty m.files)) files m

        Inspected epoch id result ->
            if epoch /= m.epoch then
                ( m, Cmd.none )

            else
                case result of
                    Err err ->
                        ( { m | busy = False, error = httpError err, phase = "" }, Cmd.none )

                    Ok count ->
                        let
                            next =
                                { m
                                    | pending =
                                        List.map
                                            (\f ->
                                                if f.id == id then
                                                    { f | pages = count }

                                                else
                                                    f
                                            )
                                            m.pending
                                }
                        in
                        if List.any (\f -> isPdf f.file && f.pages == 0) next.pending then
                            ( next, inspectNext next )

                        else
                            commitFiles next

        Remove id ->
            let
                files =
                    List.filter (\f -> f.id /= id) m.files
            in
            if m.busy then
                ( m, Cmd.none )

            else if List.isEmpty files then
                update Clear m

            else
                commitFiles { m | pending = files, attempted = files }

        Move id offset ->
            if m.busy then
                ( m, Cmd.none )

            else
                let
                    index =
                        List.indexedMap Tuple.pair m.files |> List.filter (\( _, f ) -> f.id == id) |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault 0

                    target =
                        clamp 0 (List.length m.files - 1) (index + offset)

                    moving =
                        List.filter (\f -> f.id == id) m.files

                    rest =
                        List.filter (\f -> f.id /= id) m.files

                    files =
                        List.take target rest ++ moving ++ List.drop target rest
                in
                let
                    ( next, cmd ) =
                        commitFiles { m | pending = files, attempted = files }
                in
                ( next, Cmd.batch [ cmd, bridge "focus" [ ( "id", E.string ("file-row-" ++ String.fromInt id) ) ] ] )

        Drag id ->
            ( { m | dragId = Just id }, Cmd.none )

        DropOn id ->
            case m.dragId of
                Nothing ->
                    ( m, Cmd.none )

                Just dragged ->
                    let
                        find key =
                            List.indexedMap Tuple.pair m.files |> List.filter (\( _, f ) -> f.id == key) |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault 0
                    in
                    update (Move dragged (find id - find dragged)) { m | dragId = Nothing }

        Switch op ->
            if m.busy || op == m.operation then
                ( m, Cmd.none )

            else
                let
                    next =
                        { m | operation = op, error = "", notice = "", epoch = m.epoch + 1, revision = m.revision + 1, previewToken = m.previewToken + 1 }
                in
                if op == Impose then
                    prepare next

                else
                    ( { next | source = Nothing, display = Nothing, layout = Nothing, layoutReady = False }, Cmd.batch [ Http.cancel "layout", bridge "clearPreviews" [], Maybe.map (.sourceId >> (\id -> delete ("gang-up/sources/" ++ id))) m.source |> Maybe.withDefault Cmd.none ] )

        Field key value ->
            field key value m

        CropAnchor x y ->
            let
                fit =
                    effectiveFit m
            in
            schedule { m | request = overrideFit m { fit | position = { x = x, y = y } }, drafts = Dict.remove "crop-x" (Dict.remove "crop-y" m.drafts) }

        Quantity index value ->
            let
                drafts =
                    Dict.insert index value m.quantityDrafts

                qs =
                    I.quantities m.request
                        |> List.indexedMap
                            (\i n ->
                                if i == index then
                                    String.toInt value |> Maybe.withDefault n

                                else
                                    n
                            )
            in
            if Result.toMaybe (V.whole 0 10000 value) == Nothing then
                ( { m | quantityDrafts = drafts, layoutReady = False, revision = m.revision + 1, previewToken = m.previewToken + 1, previewLoading = False }, Cmd.batch [ Http.cancel "layout", bridge "cancelPreview" [] ] )

            else
                schedule { m | quantityDrafts = drafts, request = withQuantities qs m.request }

        SetStep step ->
            if step <= m.reached then
                ( { m | step = step, rail = "setup" }, bridge "focus" [ ( "id", E.string ("step-title-" ++ String.fromInt step) ) ] )

            else
                ( m, Cmd.none )

        SetRail rail ->
            ( { m | rail = rail }, Cmd.none )

        Toggle key ->
            toggle key m

        OpenDialog name ->
            ( { m
                | dialog = name
                , rangeDraft =
                    if name == "range" then
                        (if m.operation == Split then
                            m.extractPages

                         else
                            m.imagePages
                        )
                            |> (\v ->
                                    if v == "all" then
                                        "1"

                                    else
                                        v
                               )

                    else
                        m.rangeDraft
              }
            , bridge "dialog" [ ( "id", E.string "workspace-dialog" ) ]
            )

        CloseDialog ->
            ( { m | dialog = "" }, bridge "closeDialog" [] )

        ApplyDialog ->
            applyDialog m

        Clear ->
            let
                ( fresh, _ ) =
                    init m.theme
            in
            ( { fresh | epoch = m.epoch + 1, revision = m.revision + 1, previewToken = m.previewToken + 1, presets = m.presets, recent = m.recent, history = m.history }, Cmd.batch [ Http.cancel "inspection", Http.cancel "layout", bridge "clearPreviews" [], Maybe.map (.sourceId >> (\id -> delete ("gang-up/sources/" ++ id))) m.source |> Maybe.withDefault Cmd.none ] )

        Cancel ->
            ( { m | epoch = m.epoch + 1, revision = m.revision + 1, previewToken = m.previewToken + 1, previewLoading = False, busy = False, job = Nothing, phase = "", notice = "Cancelled. Your files and settings are retained." }, Cmd.batch [ Http.cancel "inspection", Http.cancel "layout", bridge "cancelPreview" [], Maybe.map (discardJob m.jobKind) m.job |> Maybe.withDefault Cmd.none ] )

        Retry ->
            if m.retryKind == "rename" then
                update (Save "rename-preset") m

            else if String.startsWith "catalog:" m.retryKind then
                ( { m | error = "", retryKind = "" }, catalog (String.dropLeft 8 m.retryKind) )

            else if String.startsWith "save:" m.retryKind then
                save (String.dropLeft 5 m.retryKind) m

            else if m.retryKind == "inspection" then
                let
                    next =
                        { m | pending = m.attempted, epoch = m.epoch + 1, busy = True, progress = 0, phase = "Checking PDFs", error = "" }
                in
                if List.any (\f -> isPdf f.file && f.pages == 0) next.pending then
                    ( next, inspectNext next )

                else
                    commitFiles next

            else if m.retryKind == "prepare" then
                prepare m

            else if m.previewError /= "" then
                preview m

            else if m.operation == Impose && not m.layoutReady then
                schedule m

            else
                submit m

        RetryPreview ->
            if m.busy then
                ( m, Cmd.none )

            else
                preview m

        Submit ->
            submit m

        Created epoch kind result ->
            case result of
                Ok id ->
                    if epoch /= m.epoch then
                        ( m, discardJob kind (String.trim id) )

                    else
                        ( { m | job = Just (String.trim id), jobKind = kind }, Task.perform (\_ -> Poll epoch (String.trim id)) (Task.succeed ()) )

                Err err ->
                    if epoch == m.epoch then
                        ( { m | busy = False, error = httpError err, phase = "" }, Cmd.none )

                    else
                        ( m, Cmd.none )

        Poll epoch id ->
            if epoch /= m.epoch then
                ( m, Cmd.none )

            else
                ( m, Http.get { url = "jobs/" ++ id, expect = expect (Polled epoch id) Ok } )

        Polled epoch id result ->
            if epoch /= m.epoch then
                ( m, Cmd.none )

            else
                case result of
                    Err err ->
                        ( { m | busy = False, error = httpError err, job = Nothing }, delete ("jobs/" ++ id) )

                    Ok raw ->
                        let
                            status =
                                Job.parse raw
                        in
                        if status.state == "done" then
                            if m.jobKind == "prepare" then
                                ( m, Http.get { url = "jobs/" ++ id ++ "/download", expect = jsonExpect (Prepared epoch) A.preparedSourceResponseDecoder } )

                            else
                                ( { m | progress = 100, phase = "Downloading", error = "" }
                                , Cmd.batch
                                    [ bridge "download" [ ( "token", E.int m.epoch ), ( "url", E.string ("jobs/" ++ id ++ "/download") ), ( "filename", E.string status.filename ) ]
                                    , if m.operation == Impose then
                                        catalog "export-history"

                                      else
                                        Cmd.none
                                    ]
                                )

                        else if status.state == "error" then
                            ( { m
                                | busy = False
                                , error =
                                    if status.error == "" then
                                        "The job failed. Retry with your retained files and settings."

                                    else
                                        status.error
                                , job = Nothing
                              }
                            , delete ("jobs/" ++ id)
                            )

                        else if not (List.member status.state [ "queued", "running" ]) then
                            ( { m | busy = False, error = "The server returned an invalid job status. Retry the job.", job = Nothing }, delete ("jobs/" ++ id) )

                        else
                            ( { m | progress = status.percent, phase = status.stage }, Process.sleep 300 |> Task.perform (\_ -> Poll epoch id) )

        Prepared epoch result ->
            case result of
                Ok source ->
                    if epoch /= m.epoch then
                        ( m, delete ("gang-up/sources/" ++ source.sourceId) )

                    else
                        let
                            r =
                                I.bindSource source m.request

                            next =
                                { m
                                    | files =
                                        if List.isEmpty m.pending then
                                            m.files

                                        else
                                            m.pending
                                    , pending = []
                                    , source = Just source
                                    , request = r
                                    , busy = False
                                    , error = ""
                                    , job = Nothing
                                    , selectedPage = 1
                                    , sheet = 0
                                    , back = False
                                    , quantityDrafts = Dict.empty
                                    , perArtwork = False
                                    , drafts = artworkDrafts m.drafts
                                }

                            ( scheduled, cmd ) =
                                schedule next
                        in
                        ( scheduled, Cmd.batch [ cmd, bridge "source" [ ( "id", E.string source.sourceId ) ], Maybe.map (\id -> delete ("jobs/" ++ id)) m.job |> Maybe.withDefault Cmd.none, Maybe.map (.sourceId >> (\id -> delete ("gang-up/sources/" ++ id))) m.source |> Maybe.withDefault Cmd.none ] )

                Err err ->
                    if epoch == m.epoch then
                        ( { m | busy = False, error = httpError err }, Cmd.none )

                    else
                        ( m, Cmd.none )

        LayoutDue revision ->
            if revision /= m.revision || m.operation /= Impose || m.source == Nothing || not (Dict.isEmpty (Dict.filter (\key _ -> String.startsWith "invalid:" key) m.drafts)) then
                ( m, Cmd.none )

            else
                ( m, request "POST" "gang-up/layout" (Http.jsonBody (A.layoutRequestEncoder m.request)) (jsonExpect (LaidOut revision) A.layoutResultDecoder) (Just "layout") )

        LaidOut revision result ->
            if revision /= m.revision || m.operation /= Impose then
                ( m, Cmd.none )

            else
                case result of
                    Err err ->
                        ( { m | error = httpError err, layoutReady = False, retryKind = "layout" }, Cmd.none )

                    Ok layout ->
                        preview { m | layout = Just layout, layoutReady = True, error = "", sheet = min m.sheet (max 0 (layout.sheetsRequired - 1)), retryKind = "" }

        BrowserEvent event ->
            browserEvent event m

        Navigate sheet back ->
            preview { m | sheet = max 0 sheet, back = back }

        Lease _ ->
            ( m, Maybe.map (.sourceId >> (\id -> request "PUT" ("gang-up/sources/" ++ id ++ "/lease") Http.emptyBody (expect (\_ -> NoOp) Ok) Nothing)) m.source |> Maybe.withDefault Cmd.none )

        Catalog name result ->
            case result of
                Err err ->
                    ( { m | error = httpError err, retryKind = "catalog:" ++ name }, Cmd.none )

                Ok value ->
                    let
                        decoded =
                            case name of
                                "presets" ->
                                    D.decodeValue (D.list A.gangUpPresetDecoder) value |> Result.map (\xs -> { m | presets = xs })

                                "recent-jobs" ->
                                    D.decodeValue (D.list A.recentGangUpJobDecoder) value |> Result.map (\xs -> { m | recent = xs })

                                _ ->
                                    D.decodeValue (D.list A.gangUpExportRecordDecoder) value |> Result.map (\xs -> { m | history = xs })
                    in
                    case decoded of
                        Ok next ->
                            ( next, Cmd.none )

                        Err issue ->
                            ( { m | error = "Could not read saved work: " ++ D.errorToString issue, retryKind = "catalog:" ++ name }, Cmd.none )

        ApplyPreset id ->
            case List.filter (\p -> p.id == id) m.presets |> List.head of
                Nothing ->
                    ( m, Cmd.none )

                Just p ->
                    let
                        ( sided, _ ) =
                            field "sides"
                                (if p.sides == A.SidesDouble then
                                    "double"

                                 else
                                    "single"
                                )
                                m

                        ( moded, _ ) =
                            field "mode"
                                (if p.impositionMode == A.ImpositionModeRepeat then
                                    "repeat"

                                 else
                                    "unique"
                                )
                                sided

                        presetRequest =
                            I.applyPreset p moded.request
                    in
                    schedule
                        { moded
                            | request =
                                { presetRequest
                                    | duplex =
                                        if moded.request.sides == A.SidesDouble then
                                            p.duplex

                                        else
                                            Nothing
                                }
                            , drafts = Dict.empty
                            , chosenWidth = True
                            , chosenHeight = True
                            , error = ""
                            , editingPreset =
                                if p.builtIn then
                                    Nothing

                                else
                                    Just p.id
                            , savedName = p.name
                        }

        ApplySaved kind id ->
            let
                saved =
                    if kind == "recent-jobs" then
                        List.filter (\p -> p.id == id) m.recent |> List.head |> Maybe.map .request

                    else
                        List.filter (\p -> p.id == id) m.history |> List.head |> Maybe.map .request
            in
            case ( saved, m.source ) of
                ( Just r, Just source ) ->
                    schedule { m | request = I.bindSource source { r | sourceId = Nothing }, drafts = Dict.empty, quantityDrafts = Dict.empty, chosenWidth = True, chosenHeight = True, sheet = 0 }

                _ ->
                    ( { m | error = "Choose artwork before restoring a saved setup." }, Cmd.none )

        Save kind ->
            if kind == "new-preset" then
                save "presets" { m | editingPreset = Nothing }

            else if kind == "rename-preset" then
                case List.filter (\p -> Just p.id == m.editingPreset && not p.builtIn) m.presets |> List.head of
                    Just p ->
                        if String.trim m.savedName == "" then
                            ( { m | error = "Enter a name before renaming the preset." }, Cmd.none )

                        else
                            ( { m | retryKind = "rename" }, request "PUT" ("gang-up/presets/" ++ p.id) (Http.jsonBody (A.presetInputEncoder { id = Just p.id, name = m.savedName, finishedCutSize = p.finishedCutSize, parentSheetSize = p.parentSheetSize, impositionMode = p.impositionMode, finishedSizeMode = p.finishedSizeMode, artworkFit = p.artworkFit, sourceBleedOverride = p.sourceBleedOverride, bleedHandling = p.bleedHandling, createdBleedAmount = p.createdBleedAmount, gutter = p.gutter, orientationPreference = p.orientationPreference, sides = p.sides, layoutPreference = p.layoutPreference, manual = p.manual, duplex = p.duplex, outputPreference = Just p.outputPreference })) (jsonExpect (Saved "presets") D.value) Nothing )

                    Nothing ->
                        ( { m | error = "Choose a custom preset to rename." }, Cmd.none )

            else
                save kind m

        DeleteSaved kind id ->
            ( { m
                | editingPreset =
                    if kind == "presets" && m.editingPreset == Just id then
                        Nothing

                    else
                        m.editingPreset
              }
            , request "DELETE" ("gang-up/" ++ kind ++ "/" ++ id) Http.emptyBody (expect (\result -> Saved kind (Result.map (\_ -> E.null) result)) Ok) Nothing
            )

        Saved kind result ->
            case result of
                Err err ->
                    ( { m
                        | error = httpError err
                        , retryKind =
                            if String.startsWith "save:" m.retryKind || m.retryKind == "rename" then
                                m.retryKind

                            else
                                "catalog:" ++ kind
                      }
                    , Cmd.none
                    )

                Ok value ->
                    ( { m
                        | notice = "Saved work updated."
                        , error = ""
                        , retryKind = ""
                        , editingPreset =
                            if kind == "presets" then
                                D.decodeValue A.gangUpPresetDecoder value
                                    |> Result.toMaybe
                                    |> Maybe.map .id
                                    |> (\found ->
                                            if found == Nothing then
                                                m.editingPreset

                                            else
                                                found
                                       )

                            else
                                m.editingPreset
                      }
                    , catalog kind
                    )


field : String -> String -> Model -> ( Model, Cmd Msg )
field key value m =
    let
        r =
            m.request

        fit =
            effectiveFit m

        manual =
            Maybe.withDefault { rows = 1, columns = 1, rotationDegrees = 0, margins = Nothing } r.manual

        duplex =
            Maybe.withDefault { flipEdge = A.DuplexFlipEdgeLongEdge, rotateBack180 = False, backAlignment = "" } r.duplex
    in
    case key of
        "target" ->
            ( { m | target = value }, Cmd.none )

        "quality" ->
            ( { m | quality = value }, Cmd.none )

        "finished-orientation" ->
            if m.chosenWidth && m.chosenHeight then
                let
                    cut =
                        r.finishedCutSize

                    shorter =
                        min cut.width cut.height

                    longer =
                        max cut.width cut.height

                    next =
                        if value == "landscape" then
                            { width = longer, height = shorter }

                        else
                            { width = shorter, height = longer }
                in
                schedule { m | request = { r | finishedCutSize = next }, drafts = Dict.remove "finished-width" (Dict.remove "finished-height" m.drafts) }

            else
                ( m, Cmd.none )

        "pages" ->
            if m.operation == Split then
                ( { m | extractPages = value }, Cmd.none )

            else
                ( { m | imagePages = value }, Cmd.none )

        "output" ->
            ( { m | outputMode = value }, Cmd.none )

        "chunk" ->
            ( { m | chunk = value }, Cmd.none )

        "range" ->
            ( { m | rangeDraft = value }, Cmd.none )

        "bulk" ->
            ( { m | bulkDraft = value }, Cmd.none )

        "name" ->
            ( { m | savedName = value }, Cmd.none )

        "page" ->
            preview { m | selectedPage = String.toInt value |> Maybe.withDefault 1, drafts = artworkDrafts m.drafts }

        "sheet" ->
            let
                size =
                    case value of
                        "8.5x11" ->
                            { width = 8.5, height = 11 }

                        "11x17" ->
                            { width = 11, height = 17 }

                        "13x19" ->
                            { width = 13, height = 19 }

                        _ ->
                            { width = 12, height = 18 }
            in
            if value == "custom" then
                ( { m | drafts = Dict.insert "sheet-custom" "true" m.drafts }, Cmd.none )

            else
                schedule { m | request = { r | parentSheetSize = size }, drafts = Dict.remove "sheet-custom" m.drafts }

        "mode" ->
            let
                single =
                    if r.impositionMode == A.ImpositionModeRepeat && r.sides == A.SidesSingle then
                        I.quantities r

                    else
                        m.repeatSingle

                double =
                    if r.impositionMode == A.ImpositionModeRepeat && r.sides == A.SidesDouble then
                        I.quantities r

                    else
                        m.repeatDouble

                next =
                    I.setMode
                        (if value == "repeat" then
                            A.ImpositionModeRepeat

                         else
                            A.ImpositionModeUnique
                        )
                        r

                qs =
                    if r.sides == A.SidesDouble then
                        double

                    else
                        single
            in
            schedule
                { m
                    | request =
                        if value == "repeat" && not (List.isEmpty qs) then
                            withQuantities qs next

                        else
                            next
                    , repeatSingle = single
                    , repeatDouble = double
                    , quantityDrafts = Dict.empty
                }

        "sides" ->
            let
                sides =
                    if value == "double" && modBy 2 (Maybe.withDefault 1 r.sourcePageCount) == 0 then
                        A.SidesDouble

                    else
                        A.SidesSingle

                single =
                    if r.sides == A.SidesSingle && r.impositionMode == A.ImpositionModeRepeat then
                        I.quantities r

                    else
                        m.repeatSingle

                double =
                    if r.sides == A.SidesDouble && r.impositionMode == A.ImpositionModeRepeat then
                        I.quantities r

                    else
                        m.repeatDouble

                next =
                    I.setSides sides { r | impressionQuantities = Nothing }

                qs =
                    if sides == A.SidesDouble then
                        double

                    else
                        single
            in
            schedule
                { m
                    | request =
                        if r.impositionMode == A.ImpositionModeRepeat && not (List.isEmpty qs) then
                            withQuantities qs next

                        else
                            next
                    , repeatSingle = single
                    , repeatDouble = double
                    , quantityDrafts = Dict.empty
                    , back = False
                }

        "layout" ->
            let
                seed =
                    case m.layout of
                        Just l ->
                            { manual | rows = l.rows, columns = l.columns, rotationDegrees = l.rotationDegrees }

                        Nothing ->
                            manual
            in
            schedule
                { m
                    | request =
                        { r
                            | layoutMode =
                                if value == "manual" then
                                    A.LayoutModeManual

                                else
                                    A.LayoutModeMaxPieces
                            , manual =
                                if value == "manual" then
                                    Just seed

                                else
                                    Nothing
                        }
                }

        "orientation" ->
            schedule
                { m
                    | request =
                        { r
                            | manual =
                                Maybe.map
                                    (\v ->
                                        { v
                                            | rotationDegrees =
                                                if value == "quarterTurn" then
                                                    90

                                                else
                                                    0
                                        }
                                    )
                                    r.manual
                            , orientationPreference =
                                case value of
                                    "upright" ->
                                        A.OrientationPreferenceUpright

                                    "quarterTurn" ->
                                        A.OrientationPreferenceQuarterTurn

                                    "portrait" ->
                                        A.OrientationPreferencePortrait

                                    "landscape" ->
                                        A.OrientationPreferenceLandscape

                                    _ ->
                                        A.OrientationPreferenceAuto
                        }
                }

        "fit" ->
            schedule
                { m
                    | request =
                        overrideFit m
                            { fit
                                | mode =
                                    case value of
                                        "cover" ->
                                            A.ArtworkFitModeCover

                                        "stretch" ->
                                            A.ArtworkFitModeStretch

                                        _ ->
                                            A.ArtworkFitModeContain
                            }
                    , drafts = Dict.remove "crop-x" (Dict.remove "crop-y" m.drafts)
                }

        "bleed" ->
            schedule
                { m
                    | request =
                        { r
                            | bleedOption =
                                if value == "scaleToBleed" then
                                    A.BleedOptionScaleToBleed

                                else
                                    A.BleedOptionUseAsIs
                        }
                }

        "flip" ->
            schedule
                { m
                    | request =
                        { r
                            | duplex =
                                Just
                                    { duplex
                                        | flipEdge =
                                            if value == "shortEdge" then
                                                A.DuplexFlipEdgeShortEdge

                                            else
                                                A.DuplexFlipEdgeLongEdge
                                    }
                        }
                }

        "rotation" ->
            schedule { m | request = { r | manual = Just { manual | rotationDegrees = String.toInt value |> Maybe.withDefault 0 } } }

        _ ->
            setNumber key value m


toggle : String -> Model -> ( Model, Cmd Msg )
toggle key m =
    let
        r =
            m.request

        manual =
            Maybe.withDefault { rows = 1, columns = 1, rotationDegrees = 0, margins = Nothing } r.manual

        duplex =
            Maybe.withDefault { flipEdge = A.DuplexFlipEdgeLongEdge, rotateBack180 = False, backAlignment = "" } r.duplex
    in
    case key of
        "theme" ->
            let
                theme =
                    if m.theme == "dark" then
                        "light"

                    else
                        "dark"
            in
            ( { m | theme = theme }, bridge "theme" [ ( "value", E.string theme ) ] )

        "continue" ->
            if validSetup m && (m.step /= 2 || m.layoutReady) then
                ( { m | step = min 3 (m.step + 1), reached = max m.reached (min 3 (m.step + 1)) }, bridge "focus" [ ( "id", E.string ("step-title-" ++ String.fromInt (min 3 (m.step + 1))) ) ] )

            else
                ( m, Cmd.none )

        "collapse" ->
            ( { m | collapsed = not m.collapsed }, Cmd.none )

        "per-artwork" ->
            ( { m | perArtwork = not m.perArtwork, drafts = artworkDrafts m.drafts }, Cmd.none )

        "clear-override" ->
            schedule { m | request = { r | pageOverrides = List.filter (\p -> p.pageNumber /= m.selectedPage) r.pageOverrides }, drafts = artworkDrafts m.drafts }

        "clear-bleed" ->
            schedule { m | request = { r | sourceBleedOverride = Nothing }, drafts = Dict.remove "source-bleed" (Dict.remove "invalid:source-bleed" m.drafts) }

        "crop-reset" ->
            schedule { m | request = overrideFit m { mode = (effectiveFit m).mode, position = { x = 0.5, y = 0.5 } }, drafts = Dict.remove "crop-x" (Dict.remove "crop-y" (Dict.remove "invalid:crop-x" (Dict.remove "invalid:crop-y" m.drafts))) }

        "rotate-back" ->
            schedule { m | request = { r | duplex = Just { duplex | rotateBack180 = not duplex.rotateBack180 } } }

        "center" ->
            schedule
                { m
                    | request =
                        { r
                            | manual =
                                Just
                                    { manual
                                        | margins =
                                            if manual.margins == Nothing then
                                                Just (Maybe.map .margins m.layout |> Maybe.withDefault { top = 0, right = 0, bottom = 0, left = 0 })

                                            else
                                                Nothing
                                    }
                        }
                }

        "cut" ->
            ( { m | showCut = not m.showCut }, Cmd.none )

        "bleed-lines" ->
            ( { m | showBleed = not m.showBleed }, Cmd.none )

        "gutters" ->
            ( { m | showGutters = not m.showGutters }, Cmd.none )

        "paths" ->
            ( { m | showPaths = not m.showPaths }, Cmd.none )

        "zoom-in" ->
            ( { m | zoom = min 3 (m.zoom + 0.25) }, Cmd.none )

        "zoom-out" ->
            ( { m | zoom = max 0.5 (m.zoom - 0.25) }, Cmd.none )

        "zoom-fit" ->
            ( { m | zoom = 1 }, Cmd.none )

        _ ->
            ( m, Cmd.none )


applyDialog : Model -> ( Model, Cmd Msg )
applyDialog m =
    case m.dialog of
        "clear" ->
            update Clear m

        "range" ->
            let
                count =
                    List.sum (List.map .pages m.files)
            in
            case V.pages count m.rangeDraft of
                Err _ ->
                    ( m, Cmd.none )

                Ok _ ->
                    let
                        ( next, cmd ) =
                            field "pages" m.rangeDraft m
                    in
                    ( { next | dialog = "" }, Cmd.batch [ cmd, bridge "closeDialog" [] ] )

        "quantities" ->
            case V.whole 0 10000 m.bulkDraft of
                Err _ ->
                    ( m, Cmd.none )

                Ok n ->
                    let
                        ( next, cmd ) =
                            schedule { m | request = withQuantities (List.repeat (List.length (I.quantities m.request)) n) m.request, quantityDrafts = Dict.empty, drafts = Dict.remove "copies" (Dict.remove "invalid:copies" m.drafts), dialog = "" }
                    in
                    ( next, Cmd.batch [ cmd, bridge "closeDialog" [] ] )

        _ ->
            ( m, Cmd.none )


submit : Model -> ( Model, Cmd Msg )
submit m =
    if m.busy then
        ( m, Cmd.none )

    else
        let
            pages =
                if m.operation == Split then
                    m.extractPages

                else
                    m.imagePages

            count =
                List.sum (List.map .pages m.files)

            rangeValid =
                not (List.member m.operation [ PdfImage, Split ]) || pages == "all" || Result.toMaybe (V.pages count pages) /= Nothing

            chunkValid =
                m.operation /= Split || m.outputMode /= "chunks" || Result.toMaybe (V.whole 1 1000 m.chunk) /= Nothing

            dpi =
                case m.quality of
                    "print" ->
                        "300"

                    "high" ->
                        "600"

                    _ ->
                        "144"

            quality =
                case m.quality of
                    "print" ->
                        "92"

                    "high" ->
                        "95"

                    _ ->
                        "80"

            fields =
                case m.operation of
                    PdfImage ->
                        [ ( "action", "convert" ), ( "target", m.target ), ( "pages", pages ), ( "dpi", dpi ), ( "jpegQuality", quality ) ]

                    Split ->
                        [ ( "action", "split" ), ( "pages", pages ), ( "outputMode", m.outputMode ) ]
                            ++ (if m.outputMode == "chunks" then
                                    [ ( "chunkSize", m.chunk ) ]

                                else
                                    []
                               )

                    Merge ->
                        [ ( "action", "merge" ) ]

                    ImagePdf ->
                        [ ( "action", "convert" ), ( "target", "pdf" ) ]

                    Impose ->
                        [ ( "action", "gang-up-export-source" ), ( "sourceId", Maybe.map .sourceId m.source |> Maybe.withDefault "" ), ( "layoutRequest", E.encode 0 (A.layoutRequestEncoder m.request) ) ]

            parts =
                List.map (\( k, v ) -> Http.stringPart k v) fields
                    ++ (if m.operation == Impose then
                            []

                        else
                            List.map (\f -> Http.filePart "file" f.file) m.files
                       )

            next =
                { m | epoch = m.epoch + 1, busy = True, phase = "Uploading", progress = 0, error = "", notice = "", jobKind = "export", retryKind = "export", job = Nothing }
        in
        if List.isEmpty m.files || not rangeValid || not chunkValid || (m.operation == Impose && (not (validSetup m) || not m.layoutReady)) then
            ( { m | error = "Correct the highlighted settings before exporting." }, Cmd.none )

        else
            ( next, request "POST" "jobs" (Http.multipartBody parts) (expect (Created next.epoch "export") Ok) (Just "job-upload") )


browserEvent : D.Value -> Model -> ( Model, Cmd Msg )
browserEvent event m =
    let
        get key decoder fallback =
            D.decodeValue (D.field key decoder) event |> Result.withDefault fallback

        action =
            get "action" D.string ""

        token =
            get "token" D.int -1
    in
    case action of
        "preview" ->
            if token /= m.previewToken || m.operation /= Impose then
                ( m, Cmd.none )

            else
                case ( m.layout, m.source ) of
                    ( Just layout, Just source ) ->
                        let
                            urls =
                                get "urls" (D.list (D.map2 Tuple.pair (D.field "page" D.int) (D.field "url" D.string))) [] |> Dict.fromList
                        in
                        ( { m | display = Just { layout = layout, urls = urls, sheet = m.sheet, back = m.back, source = source.sourceId }, previewLoading = False, previewError = "" }, bridge "commitPreview" [ ( "source", E.string source.sourceId ), ( "urls", E.list E.string (Dict.values urls) ) ] )

                    _ ->
                        ( m, Cmd.none )

        "previewError" ->
            if token == m.previewToken then
                ( { m | previewLoading = False, previewError = get "message" D.string "Preview failed. Retry.", retryKind = "preview" }, Cmd.none )

            else
                ( m, Cmd.none )

        "downloadError" ->
            if token == m.epoch then
                ( { m | busy = False, job = Nothing, error = get "message" D.string "Download failed. Retry.", notice = "" }, Maybe.map (\id -> delete ("jobs/" ++ id)) m.job |> Maybe.withDefault Cmd.none )

            else
                ( m, Cmd.none )

        "downloadDone" ->
            if token == m.epoch then
                ( { m | busy = False, job = Nothing, notice = get "filename" D.string "Download" ++ " was sent to your browser." }, Cmd.none )

            else
                ( m, Cmd.none )

        "visible" ->
            update (Lease (Time.millisToPosix 0)) m

        "crop" ->
            let
                fit =
                    effectiveFit m

                x =
                    clamp 0 1 (get "x" D.float fit.position.x)

                y =
                    clamp 0 1 (get "y" D.float fit.position.y)
            in
            schedule { m | request = overrideFit m { fit | position = { x = x, y = y } }, drafts = Dict.remove "crop-x" (Dict.remove "crop-y" m.drafts) }

        "theme" ->
            ( { m | theme = get "value" D.string m.theme }, Cmd.none )

        "closeDialog" ->
            ( { m | dialog = "" }, Cmd.none )

        _ ->
            ( m, Cmd.none )


artworkDrafts : Dict.Dict String String -> Dict.Dict String String
artworkDrafts drafts =
    Dict.filter
        (\key _ ->
            let
                fieldKey =
                    if String.startsWith "invalid:" key then
                        String.dropLeft 8 key

                    else
                        key
            in
            not (String.startsWith "artwork-" fieldKey || String.startsWith "crop-" fieldKey)
        )
        drafts


save : String -> Model -> ( Model, Cmd Msg )
save kind m =
    if not (validSetup m) || not m.layoutReady || String.isEmpty (String.trim m.savedName) then
        ( { m | error = "Enter a name and complete a valid setup before saving." }, Cmd.none )

    else
        let
            r =
                m.request

            payload =
                if kind == "presets" then
                    A.presetInputEncoder { id = m.editingPreset, name = m.savedName, finishedCutSize = r.finishedCutSize, parentSheetSize = r.parentSheetSize, impositionMode = r.impositionMode, finishedSizeMode = r.finishedSizeMode, artworkFit = r.artworkFit, sourceBleedOverride = r.sourceBleedOverride, bleedHandling = r.bleedOption, createdBleedAmount = r.createdBleedAmount, gutter = r.gutter, orientationPreference = r.orientationPreference, sides = r.sides, layoutPreference = r.layoutMode, manual = r.manual, duplex = r.duplex, outputPreference = Just A.OutputPreferenceCleanPdf }

                else
                    A.recentGangUpJobInputEncoder { name = Just m.savedName, sourceFilename = List.head m.files |> Maybe.map (.file >> File.name), request = r, layoutSummary = Maybe.map I.summary m.layout }

            ( method, url ) =
                if kind == "presets" then
                    case m.editingPreset of
                        Just id ->
                            ( "PUT", "gang-up/presets/" ++ id )

                        Nothing ->
                            ( "POST", "gang-up/presets" )

                else
                    ( "POST", "gang-up/recent-jobs" )
        in
        ( { m | retryKind = "save:" ++ kind }, request method url (Http.jsonBody payload) (jsonExpect (Saved kind) D.value) Nothing )


discardJob : String -> String -> Cmd Msg
discardJob kind id =
    if kind == "prepare" then
        Http.get { url = "jobs/" ++ id ++ "/download", expect = jsonExpect (Discarded id) A.preparedSourceResponseDecoder }

    else
        delete ("jobs/" ++ id)
