port module SupervisedTargets exposing (..)

import Html exposing (..)
import Html.Attributes exposing ( style, class, type_, checked )
import Html.Events exposing (..)
import String
import List.Extra exposing (uniqueBy)
import Toasty
import Toasty.Defaults
import Http exposing (Error)
import Http exposing (..)
import Json.Encode as E
import Json.Decode as D exposing (Decoder)
import Json.Decode.Pipeline exposing(..)

------------------------------
-- SUBSCRIPTIONS
------------------------------

subscriptions : Model -> Sub Msg
subscriptions   model =  Sub.none

------------------------------
-- Init and main --
------------------------------

init : { contextPath: String } -> (Model, Cmd Msg)
init flags =
  let
    initModel = Model flags.contextPath (Category "waiting for server data..." (Subcategories []) []) Toasty.initialState
  in
    initModel ! [ getTargets initModel ]

main = programWithFlags
    { init = init
    , view = view
    , update = update
    , subscriptions = subscriptions
    }


------------------------------
-- MODEL --
------------------------------

type alias Target =
  { id         : String -- id
  , name       : String -- display name of the rule target
  , description: String -- description
  , supervised : Bool   -- do you want to validate CR targeting that rule target
  }

type alias Category =
  { name       : String        -- name of the category
  , categories : Subcategories -- sub-categories
  , targets    : List Target   -- targets in category
  }

type Subcategories = Subcategories (List Category) -- needed because no recursive type alias support

type alias Model =
  { contextPath: String
  , allTargets : Category    -- from API
  , toasties   : Toasty.Stack Toasty.Defaults.Toast
  }

type Msg
  = GetTargets (Result Error Category)
  | SaveTargets (Result Error String) -- here the string is just the status message
  | SendSave
  | UpdateTarget Target
  -- NOTIFICATIONS
  | ToastyMsg (Toasty.Msg Toasty.Defaults.Toast)


------------------------------
-- API --
------------------------------

-- API call to get the category tree
getTargets : Model -> Cmd Msg
getTargets model =
  let
    url     = (model.contextPath ++ "/secure/api/changevalidation/supervised/targets")
    headers = []
    req = request {
        method          = "GET"
      , headers         = []
      , url             = url
      , body            = emptyBody
      , expect          = expectJson decodeApiCategory
      , timeout         = Nothing
      , withCredentials = False
      }
  in
    send GetTargets req

-- 
saveTargets : Model -> Cmd Msg
saveTargets model =
 let
   req = request {
             method = "POST"
           , headers = []
           , url = model.contextPath ++ "/secure/api/changevalidation/supervised/targets"
           , body = jsonBody (encodeTargets (getSupervisedIds model.allTargets))
           , expect = expectJson decodeApiSave
           , timeout = Nothing
           , withCredentials = False
         }
 in
    send SaveTargets req

-- utility method to find all targets checked as "supervised"
getSupervisedIds : Category -> List String
getSupervisedIds cat =
  case cat.categories of
    Subcategories subcats ->
      let
        fromTargets = cat.targets |> List.filterMap (\t -> if t.supervised then (Just t.id) else Nothing)
      in
        List.concat (fromTargets :: (subcats |> List.map (\c -> getSupervisedIds c)))



-- encode / decode JSON

-- decode the JSON answer from a "save" API call. Just check status message.
decodeApiSave : Decoder String
decodeApiSave = D.at ["result"] D.string


-- decode the JSON answer from a "get" API call - only "data" field content is interesting
decodeApiCategory : Decoder Category
decodeApiCategory =
  D.at ["data" ] decodeCategory


decodeCategory : Decoder Category
decodeCategory =
    decode Category
      |> required "name"       D.string
      |> required "categories" decodeSubcategories
      |> required "targets"    (D.list decodeTarget)

decodeSubcategories : Decoder Subcategories
decodeSubcategories =
    D.map Subcategories (D.list (D.lazy (\_ -> decodeCategory)))


decodeTarget : Decoder Target
decodeTarget =
  decode Target
    |> required "id"          D.string
    |> required "name"        D.string
    |> required "description" D.string
    |> required "supervised"  D.bool



-- when we encode targets, we only care about the id of the target
encodeTargets : List String -> E.Value
encodeTargets targets =
    E.object [ ("supervised", E.list <| (targets |> List.map (\s -> E.string s)) )]


------------------------------
-- UPDATE --
------------------------------

update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
  case msg of
{-- Api Calls message --}
    GetTargets result  ->
      case result of
        Ok category ->
          let
            newModel = { model | allTargets = category }
          in
            (newModel, Cmd.none)
        Err err  ->
          (model, Cmd.none)
            |> (createErrorNotification "Error while trying to fetch settings." err)

    SaveTargets result ->
      case result of
        Ok msg ->
            (model, Cmd.none) |> (createSuccessNotification ("Your changes have been saved." ))
        Err err  ->
          (model, Cmd.none)
            |> (createErrorNotification "Error while trying to save changes." err)

    SendSave ->
      (model, saveTargets model)


    UpdateTarget target ->
        let newModel = {model | allTargets = updateTarget target model.allTargets }
        in (newModel, Cmd.none)


    ToastyMsg subMsg ->
      Toasty.update defaultConfig ToastyMsg subMsg model

-- utility method the replace a target in Category (or its children) based on its id.
-- If several targets have the same id in the category tree, all are replaced.
updateTarget : Target -> Category -> Category
updateTarget target cat =
  let
    updatedCats = case cat.categories of
        Subcategories subcats -> subcats |> List.map (\c -> updateTarget target c)
    updatedTargets = cat.targets |> List.map (\t -> if t.id == target.id then target else t)
  in
    Category cat.name (Subcategories updatedCats) updatedTargets

------------------------------
-- VIEW --
------------------------------

view: Model -> Html Msg
view model =
  div [] [
      div [] [(displayCategory model.allTargets)]
    , div [] [
        button [onClick SendSave] [text "Save"]
      ]
    , div[class "toasties"][Toasty.view defaultConfig Toasty.Defaults.view ToastyMsg model.toasties]
  ]


displaySubcategories: Subcategories -> List (Html Msg)
displaySubcategories (Subcategories categories) =
  categories |> List.map (\cat    -> displayCategory cat )

displayCategory: Category -> Html Msg
displayCategory category =
  let
    subcats = displaySubcategories category.categories
    targets = category.targets    |> List.map (\target -> displayTarget target)
  in
    li [] (
      h3 [] [ (text category.name) ] ::
      (ul [] subcats) ::
      targets
    )

displayTarget: Target -> Html Msg
displayTarget target =
  li [ (style [("padding", "10px")]) ] [
    div [] [
        (b [] [(text target.name)])
      , (input [
              type_ "checkbox"
            , style [("margin", "0 0 -5px 15px")]
            , checked target.supervised
            , onClick (UpdateTarget {target| supervised = not target.supervised })
            ]
            []
        )
    ]
  , div[][
      if not (String.isEmpty target.description) then
        (span [style [("margin", "5px")]] [(text target.description)])
      else (text "")
    ]
  ]


------------------------------
-- NOTIFICATIONS --
------------------------------

getErrorMessage : Http.Error -> String
getErrorMessage e =
  let
    errMessage = case e of
      Http.BadStatus b         -> let
                                    status = b.status
                                    message = status.message
                                  in
                                    ("Code "++Basics.toString(status.code)++" : "++message)
      Http.BadUrl str          -> "Invalid API url"
      Http.Timeout             -> "It took too long to get a response"
      Http.NetworkError        -> "Network error"
      Http.BadPayload str rstr -> str
  in
    errMessage


defaultConfig : Toasty.Config Msg
defaultConfig =
  Toasty.Defaults.config
    |> Toasty.delay 999999999
    |> Toasty.containerAttrs
    [ style
        [ ( "position", "fixed" )
        , ( "top", "50px" )
        , ( "right", "30px" )
        , ( "width", "100%" )
        , ( "max-width", "500px" )
        , ( "list-style-type", "none" )
        , ( "padding", "0" )
        , ( "margin", "0" )
        ]
    ]

tempConfig : Toasty.Config Msg
tempConfig = defaultConfig |> Toasty.delay 3000


addTempToast : Toasty.Defaults.Toast -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
addTempToast toast ( model, cmd ) =
  Toasty.addToast tempConfig ToastyMsg toast ( model, cmd )

addToast : Toasty.Defaults.Toast -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
addToast toast ( model, cmd ) =
  Toasty.addToast defaultConfig ToastyMsg toast ( model, cmd )

createSuccessNotification : String -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
createSuccessNotification message =
  addTempToast (Toasty.Defaults.Success "Success!" message)

createErrorNotification : String -> Http.Error -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
createErrorNotification message e =
  addToast (Toasty.Defaults.Error "Error..." (message ++ " ("++(getErrorMessage e)++")"))

createDecodeErrorNotification : String -> String -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
createDecodeErrorNotification message e =
  addToast (Toasty.Defaults.Error "Error..." (message ++ " ("++(e)++")"))
