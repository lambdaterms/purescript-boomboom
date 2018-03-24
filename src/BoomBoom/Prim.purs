module BoomBoom.Prim where

import Prelude

import Control.Alt (class Alt, (<|>))
import Data.Either (Either(Right, Left))
import Data.Maybe (Maybe(..))
import Data.Monoid (class Monoid, mempty)
import Data.Newtype (class Newtype)
import Data.Record (get, insert)
import Data.Variant (Variant, inj, on)
import Partial.Unsafe (unsafeCrashWith)
import Type.Prelude (class IsSymbol, class RowLacks, SProxy)

-- | Our core type - nearly an iso:
-- | `{ ser: a → tok, prs: tok → Maybe a }`
newtype BoomBoom tok a = BoomBoom (BoomBoomD tok a a)
derive instance newtypeBoomBoom ∷ Newtype (BoomBoom tok a) _

-- | __D__ from diverging as `a'` can diverge from `a`
-- | and `tok'` can diverge from tok.
-- |
-- | I hope that I drop this additional tok' soon
newtype BoomBoomD tok a' a = BoomBoomD
  { prs ∷ tok → Maybe { a ∷ a, tok ∷ tok }
  , ser ∷ a' → tok
  }
derive instance newtypeBoomBoomD ∷ Newtype (BoomBoomD tok a' a) _
derive instance functorBoomBoomD ∷ Functor (BoomBoomD tok a')

-- | `divergeA` together with `BoomBoomD` `Applicative`
-- | instance form quite nice API to create by hand
-- | `BoomBooms` for records (or other product types):
-- |
-- | recordB ∷ BoomBoom String {x :: Int, y :: Int}
-- | recordB = BoomBoom $
-- |   {x: _, y: _}
-- |   <$> _.x >- int
-- |   <* lit "/"
-- |   <*> _.y >- int
-- |
-- | This manual work is tedious and can
-- | lead to incoherency in final `BoomBoom`
-- | - serializer can produce something which
-- | is not parsable or the other way around.
-- | Probably there are case where you want
-- | it so here it is.
-- |
divergeA ∷ ∀ a a' tok. (a' → a) → BoomBoom tok a → BoomBoomD tok a' a
divergeA d (BoomBoom (BoomBoomD { prs, ser })) = BoomBoomD { prs, ser: d >>> ser }

infixl 5 divergeA as >-

instance applyBoomBoomD ∷ (Semigroup tok) ⇒ Apply (BoomBoomD tok a') where
  apply (BoomBoomD b1) (BoomBoomD b2) = BoomBoomD { prs, ser }
    where
    prs t = do
      { a: f, tok: t' } ← b1.prs t
      { a, tok: t'' } ← b2.prs t'
      pure { a: f a, tok: t'' }
    ser = (<>) <$> b1.ser <*> b2.ser

instance applicativeBoomBoomD ∷ (Monoid tok) ⇒ Applicative (BoomBoomD tok a') where
  pure a = BoomBoomD { prs: pure <<< const { a, tok: mempty }, ser: const mempty }

-- | This `Alt` instance is also somewhat dangerous - it allows
-- | you to define inconsistent `BoomBoom` in case for example
-- | of your sum type so you can get `tok's` `mempty` as a result
-- | of serialization which is not parsable.
instance altBoomBoom ∷ (Monoid tok) ⇒ Alt (BoomBoomD tok a') where
  alt (BoomBoomD b1) (BoomBoomD b2) = BoomBoomD { prs, ser }
    where
    -- | Piece of premature optimization ;-)
    prs tok = case b1.prs tok of
      Nothing → b2.prs tok
      r → r
    ser = (<>) <$> b1.ser <*> b2.ser

-- | Enter the world of two categories which fully keep track of
-- | `BoomBoom` divergence and allow us define constructors
-- | for secure record and variant `BoomBooms`.
newtype BoomBoomPrsAFn tok a r r' = BoomBoomPrsAFn (BoomBoomD tok a (r → r'))

instance semigroupoidBoomBoomPrsAFn ∷ (Semigroup tok) ⇒ Semigroupoid (BoomBoomPrsAFn tok a) where
  compose (BoomBoomPrsAFn (BoomBoomD b1)) (BoomBoomPrsAFn (BoomBoomD b2)) = BoomBoomPrsAFn $ BoomBoomD
    { prs: \tok → do
        { a: r, tok: tok' } ← b2.prs tok
        { a: r', tok: tok'' } ← b1.prs tok'
        pure {a: r' <<< r, tok: tok''}
    , ser: (<>) <$> b1.ser <*> b2.ser
    }

instance categoryBoomBoomPrsAFn ∷ (Monoid tok) ⇒ Category (BoomBoomPrsAFn tok a) where
  id = BoomBoomPrsAFn $ BoomBoomD
    { prs: \tok → pure { a: id, tok }
    , ser: const mempty
    }

newtype BoomBoomSerFn tok a v v' = BoomBoomSerFn (BoomBoomD tok ((v → v') → tok) a)

instance semigroupoidBoomBoomSerFn ∷ (Semigroup tok) ⇒ Semigroupoid (BoomBoomSerFn tok a) where
  compose (BoomBoomSerFn (BoomBoomD b1)) (BoomBoomSerFn (BoomBoomD b2)) = BoomBoomSerFn $ BoomBoomD
    { prs: \tok → b1.prs tok <|> b2.prs tok
    , ser: \a2c2t → b2.ser (\a2b → b1.ser (\b2c → a2c2t (a2b >>> b2c)))
    }

lit ∷ ∀ tok a'. tok -> BoomBoomD tok a' Unit
lit tok = BoomBoomD
  { prs: const (Just { a: unit, tok })
  , ser: const tok
  }

-- | Our category allows us to step by step
-- | contract our variant:
-- |
-- |     (((Either a tok → Either b tok) → tok) → tok)
-- | >>> (((Either b tok → Either c tok) → tok) → tok)
-- | =   (((Either a tok → Either c tok) → tok) → tok)
-- |
-- | Where `a, b, c` is our contracting variant
-- | series.
-- |
addChoice
  ∷ forall a r r' s s' n tok
  . RowCons n a r' r
  ⇒ RowCons n a s s'
  ⇒ IsSymbol n
  ⇒ Semigroup tok
  ⇒ SProxy n
  -- → (∀ a'. SProxy n → BoomBoomD tok a' Unit)
  → BoomBoom tok a
  → BoomBoomSerFn tok (Variant s') (Either (Variant r) tok) (Either (Variant r') tok)
addChoice p (BoomBoom (BoomBoomD b)) = BoomBoomSerFn $ choice -- (lit p *> choice)
  where
  choice = BoomBoomD
    { prs: b.prs >=> \{a, tok} → pure { a: inj p a, tok }
    , ser: \a2eb2tok → a2eb2tok (case _ of
        Left v → on p (Right <<< b.ser) Left v
        Right tok → Right tok)
    }

-- | ser ∷ (((Either (Variant r) tok → Either (Variant ()) tok) → tok) → tok)
buildVariant
  ∷ ∀ tok r
  . BoomBoomSerFn tok (Variant r) (Either (Variant r) tok) (Either (Variant ()) tok)
  → BoomBoom tok (Variant r)
buildVariant (BoomBoomSerFn (BoomBoomD {prs, ser})) = BoomBoom $ BoomBoomD
  { prs
  , ser: \v → ser (\a2t2t → (case (a2t2t (Left v)) of
      (Left _) → unsafeCrashWith "BoomBoom.Prim.buildVariant: empty variant?"
      (Right tok) → tok))
  }

addField ∷ ∀ a n r r' s s' tok
  . RowCons n a s s'
  ⇒ RowLacks n s
  ⇒ RowCons n a r r'
  ⇒ RowLacks n r
  ⇒ IsSymbol n
  ⇒ SProxy n
  → BoomBoom tok a
  → BoomBoomPrsAFn tok { | s'} { | r } { | r'}
addField p (BoomBoom (BoomBoomD b)) = BoomBoomPrsAFn $ BoomBoomD
  { prs: \t → b.prs t <#> \{a, tok} →
      { a: \r → insert p a r, tok }
  , ser: \r → b.ser (get p r)
  }

buildRecord
  ∷ ∀ r tok
  . BoomBoomPrsAFn tok r {} r
  → BoomBoom tok r
buildRecord (BoomBoomPrsAFn (BoomBoomD b)) = BoomBoom $ BoomBoomD
  { prs: \tok → do
      {a: r2r, tok: tok'} ← b.prs tok
      pure {a: r2r {}, tok: tok'}
  , ser: b.ser
  }

