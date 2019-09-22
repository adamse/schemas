{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Schemas.Class where

import           Control.Lens         hiding (_Empty, Empty, enum, (<.>))
import           Data.Aeson           (Value)
import           Data.Biapplicative
import           Data.Generics.Labels ()
import           Data.Hashable
import           Data.HashMap.Strict  (HashMap)
import qualified Data.HashMap.Strict  as Map
import           Data.HashSet         (HashSet)
import           Data.List.NonEmpty   (NonEmpty (..))
import           Data.Maybe
import           Data.Scientific
import           Data.Text            (Text, pack, unpack)
import           Data.Vector          (Vector)
import           Numeric.Natural
import           Schemas.Internal
import           Schemas.Untyped

-- HasSchema class and instances
-- -----------------------------------------------------------------------------------

class HasSchema a where
  schema :: TypedSchema a

instance HasSchema () where
  schema = mempty

instance HasSchema Bool where
  schema = viaJSON "Bool"

instance HasSchema Double where
  schema = viaJSON "Double"

instance HasSchema Scientific where
  schema = viaJSON "Double"

instance HasSchema Int where
  schema = viaJSON "Int"

instance HasSchema Integer where
  schema = viaJSON "Integer"

instance HasSchema Natural where
  schema = viaJSON "Natural"

instance {-# OVERLAPPING #-} HasSchema String where
  schema = string

instance HasSchema Text where
  schema = viaJSON "String"

instance {-# OVERLAPPABLE #-} HasSchema a => HasSchema [a] where
  schema = list schema

instance HasSchema a => HasSchema (Vector a) where
  schema = TArray schema id id

instance (Eq a, Hashable a, HasSchema a) => HasSchema (HashSet a) where
  schema = list schema

instance  HasSchema a => HasSchema (NonEmpty a) where
  schema = list schema

instance HasSchema Field where
  schema = record $ Field <$> field "schema" fieldSchema <*> fmap
    (fromMaybe True)
    (optField "isRequired" (\x -> if isRequired x then Nothing else Just False))

instance HasSchema a => HasSchema (Identity a) where
  schema = dimap runIdentity Identity schema

instance HasSchema Schema where
  schema = union'
    [ alt "StringMap" #_StringMap
    , alt "Array"     #_Array
    , alt "Enum"      #_Enum
    , alt "Record"    #_Record
    , alt "Empty"      _Empty
    , alt "AllOf"     #_AllOf
    , alt "Prim"      #_Prim
    , altWith unionSchema "Union" _Union
    , alt "OneOf"     #_OneOf
    ]
    where
      unionSchema = list (record $ (,) <$> field "constructor" fst <*> field "schema" snd)

instance HasSchema Value where
  schema = viaJSON "JSON"

instance (HasSchema a, HasSchema b) => HasSchema (a,b) where
  schema = record $ (,) <$> field "$1" fst <*> field "$2" snd

instance (HasSchema a, HasSchema b, HasSchema c) => HasSchema (a,b,c) where
  schema = record $ (,,) <$> field "$1" (view _1) <*> field "$2" (view _2) <*> field "$3" (view _3)

instance (HasSchema a, HasSchema b, HasSchema c, HasSchema d) => HasSchema (a,b,c,d) where
  schema =
    record
      $   (,,,)
      <$> field "$1" (view _1)
      <*> field "$2" (view _2)
      <*> field "$3" (view _3)
      <*> field "$4" (view _4)

instance (HasSchema a, HasSchema b, HasSchema c, HasSchema d, HasSchema e) => HasSchema (a,b,c,d,e) where
  schema =
    record
      $   (,,,,)
      <$> field "$1" (view _1)
      <*> field "$2" (view _2)
      <*> field "$3" (view _3)
      <*> field "$4" (view _4)
      <*> field "$5" (view _5)

instance (HasSchema a, HasSchema b) => HasSchema (Either a b) where
  schema = union' [alt "Left" #_Left, alt "Right" #_Right]

instance (Eq key, Hashable key, HasSchema a, Key key) => HasSchema (HashMap key a) where
  schema = dimap toKeyed fromKeyed $ stringMap schema
    where
      fromKeyed :: HashMap Text a -> HashMap key a
      fromKeyed = Map.fromList . map (first fromKey) . Map.toList
      toKeyed :: HashMap key a -> HashMap Text a
      toKeyed = Map.fromList . map (first toKey) . Map.toList

class Key a where
  fromKey :: Text -> a
  toKey :: a -> Text

instance Key Text where
  fromKey = id
  toKey = id

instance Key String where
  fromKey = unpack
  toKey   = pack

-- HasSchema aware combinators
-- -----------------------------------------------------------------------------------

theSchema :: forall a . HasSchema a => Schema
theSchema = extractSchema (schema @a)

validatorsFor :: forall a . HasSchema a => Validators
validatorsFor = extractValidators (schema @a)

-- | encode using the default schema
encode :: HasSchema a => a -> Value
encode = encodeWith schema

encodeTo :: HasSchema a => Schema -> Maybe (a -> Value)
encodeTo = encodeToWith schema

-- | Encode a value into a finite representation by enforcing a max depth
finiteEncode :: forall a. HasSchema a => Natural -> a -> Value
finiteEncode d = finiteValue (validatorsFor @a) d (theSchema @a) . encode

decode :: HasSchema a => Value -> Either [(Trace, DecodeError)] a
decode = decodeWith schema

decodeFrom :: HasSchema a => Schema -> Maybe (Value -> Either [(Trace, DecodeError)] a)
decodeFrom = decodeFromWith schema

-- | Coerce from 'sub' to 'sup'Returns 'Nothing' if 'sub' is not a subtype of 'sup'
coerce :: forall sub sup . (HasSchema sub, HasSchema sup) => Value -> Maybe Value
coerce = case isSubtypeOf (validatorsFor @sub) (theSchema @sub) (theSchema @sup) of
  Just cast -> Just . cast
  Nothing   -> const Nothing

field :: HasSchema a => Text -> (from -> a) -> RecordFields from a
field = fieldWith schema

optField :: forall a from. HasSchema a => Text -> (from -> Maybe a) -> RecordFields from (Maybe a)
optField n get = optFieldWith (lmap get $ liftMaybe (schema @a)) n

optFieldEither
    :: forall a from e
     . HasSchema a
    => Text
    -> (from -> Either e a)
    -> e
    -> RecordFields from (Either e a)
optFieldEither n x e = optFieldGeneral (lmap x $ liftEither schema) n (Left e)

alt :: HasSchema a => Text -> Prism' from a -> UnionTag from
alt = altWith schema
