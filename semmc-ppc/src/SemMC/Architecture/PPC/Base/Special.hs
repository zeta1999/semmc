{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImplicitParams #-}
module SemMC.Architecture.PPC.Base.Special (
  baseSpecial
  ) where

import Prelude hiding ( concat )
import SemMC.DSL
import SemMC.Architecture.PPC.Base.Core

baseSpecial :: (?bitSize :: BitSize) => SemM 'Top ()
baseSpecial = do
  defineOpcodeWithIP "MFCR" $ do
    comment "Move From Condition Register"
    rT <- param "rT" gprc naturalBV
    input cr
    defLoc rT (zext (Loc cr))
{-
  defineOpcodeWithIP "MTOCRF" $ do
    comment "Move To One Condition Register Field (XFX-form)"
    crbit <- param "FXM" crbitm (EBV 8)
    rS <- param "rS" gprc naturalBV
    input rS
    input crbit
    input cr
    -- Check the number of bits set in the field; if it is 1, then we set that
    -- field.  Otherwise, we are undefined.  FIXME: We don't have a great way to
    -- set something undefined for now...
    let check = bvpopcnt (zext' 32 (Loc crbit))
    let fldIdx = bvclz (zext' 32 (Loc crbit))
    let regContents = lowBits 32 (Loc rS)
    let shifted = bvlshr regContents (bvmul fldIdx (LitBV 32 0x4))
    let nibble = lowBits 4 shifted

    -- Save the high bits in a word with the target and low bits cleared (via shifting)
    -- Save the low bits in a word with the target and high bits cleared (via shifting)
    -- Shift the new field into place and OR everything together
    let newCR = undefined
    let res = ite (bveq check (LitBV 32 0x1)) newCR (naturalLitBV 0x0)
    defLoc cr res
-}
