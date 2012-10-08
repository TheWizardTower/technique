--
-- Procedures
--
-- Copyright © 2012 Operational Dynamics Consulting, Pty Ltd
--
-- The code in this file, and the program it is a part of, is made available
-- to you by its authors as open source software: you can redistribute it
-- and/or modify it under the terms of the GNU General Public License version
-- 2 ("GPL") as published by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE. See the GPL for more details.
--
-- You should have received a copy of the GPL along with this program. If not,
-- see http://www.gnu.org/licenses/. The authors of this program may be
-- contacted through http://research.operationaldynamics.com/
--

{-# LANGUAGE OverloadedStrings #-}

module MockData (spec) where
 
import Test.Hspec (Spec, describe, it)

import Utilities (assertPass)
import Lookup (storeResource)


spec :: Spec
spec = do
    describe "Load mock data for tests" $ do
        testSetFakeData


testSetFakeData =
  it "store mock data" $ do
        storeResource "254" "{\"president\": \"Kennedy\"}\n"
        storeResource "42:config" "[null]"
        assertPass




