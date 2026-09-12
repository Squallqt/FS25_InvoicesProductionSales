-- Copyright © 2026 Squallqt. All rights reserved.
---Pure helpers shared by production sales runtime and isolated tests.
IPS_Util = {}

IPS_Util.EPSILON = 0.0001
IPS_Util.MAX_INT32 = 2147483647

---Returns whether a value is a finite number.
-- @param any value Candidate value
-- @return boolean True for finite numbers
function IPS_Util.isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

---Validates a seller price expressed tax-inclusive per 1000 liters.
-- @param any value Candidate price
-- @return number|nil Valid price or nil
function IPS_Util.sanitizePrice(value)
    value = tonumber(value)
    if not IPS_Util.isFiniteNumber(value)
        or value < 1
        or value > IPS_Util.MAX_INT32
        or value ~= math.floor(value) then
        return nil
    end
    return value
end

---Validates a positive integer quantity selected for a public offer.
-- @param any value Candidate quantity
-- @return number|nil Valid quantity or nil
function IPS_Util.sanitizeQuantity(value)
    value = tonumber(value)
    if not IPS_Util.isFiniteNumber(value)
        or value < 1
        or value > IPS_Util.MAX_INT32
        or value ~= math.floor(value) then
        return nil
    end
    return value
end

---Rounds a non-negative currency amount exactly like Invoice.
-- @param number value Raw amount
-- @return number Rounded amount
function IPS_Util.roundCurrency(value)
    if MathUtil ~= nil and MathUtil.round ~= nil then
        return MathUtil.round(value)
    end
    return math.floor((value or 0) + 0.5)
end

---Computes a tax-inclusive line amount for liters.
-- @param number price Price per 1000 liters
-- @param number liters Quantity in liters
-- @param table? invoiceClass Invoice class exposing computeLineGross
-- @return number Rounded gross amount
function IPS_Util.computeGross(price, liters, invoiceClass)
    if invoiceClass ~= nil and invoiceClass.computeLineGross ~= nil then
        return invoiceClass.computeLineGross(price, liters, invoiceClass.UNIT_LITER)
    end
    return IPS_Util.roundCurrency((price or 0) * (liters or 0) / 1000)
end

---Extracts VAT and net amount from one tax-inclusive amount.
-- @param number gross Tax-inclusive amount
-- @param number vatRate VAT rate as fraction
-- @return number net Net amount
-- @return number vat VAT amount
function IPS_Util.computeNetAndVat(gross, vatRate)
    gross = IPS_Util.roundCurrency(math.max(gross or 0, 0))
    vatRate = IPS_Util.isFiniteNumber(vatRate) and math.max(vatRate, 0) or 0
    local vat = 0
    if vatRate > 0 then
        vat = math.floor(gross * vatRate / (1 + vatRate) + 0.5)
    end
    return gross - vat, vat
end

---Computes cumulative money differences for an added volume.
-- @param number price Price per 1000 liters
-- @param number oldLiters Existing cumulative liters
-- @param number addedLiters Newly transferred liters
-- @param number vatRate VAT rate as fraction
-- @param table? invoiceClass Invoice class
-- @return table Difference and new cumulative totals
function IPS_Util.computeCumulativeDelta(price, oldLiters, addedLiters, vatRate, invoiceClass)
    oldLiters = math.max(oldLiters or 0, 0)
    addedLiters = math.max(addedLiters or 0, 0)

    local oldGross = IPS_Util.computeGross(price, oldLiters, invoiceClass)
    local newLiters = oldLiters + addedLiters
    local newGross = IPS_Util.computeGross(price, newLiters, invoiceClass)
    local oldNet, oldVat = IPS_Util.computeNetAndVat(oldGross, vatRate)
    local newNet, newVat = IPS_Util.computeNetAndVat(newGross, vatRate)

    return {
        liters = newLiters,
        gross = newGross,
        net = newNet,
        vat = newVat,
        deltaGross = newGross - oldGross,
        deltaNet = newNet - oldNet,
        deltaVat = newVat - oldVat
    }
end

---Finds the largest requested volume affordable under cumulative rounding.
-- @param number price Price per 1000 liters
-- @param number oldLiters Existing cumulative liters
-- @param number requestedLiters Requested additional liters
-- @param number availableMoney Buyer balance
-- @param table? invoiceClass Invoice class
-- @return number Affordable additional liters
function IPS_Util.getAffordableLiters(price, oldLiters, requestedLiters, availableMoney, invoiceClass)
    requestedLiters = math.max(requestedLiters or 0, 0)
    oldLiters = math.max(oldLiters or 0, 0)
    availableMoney = math.max(math.floor(availableMoney or 0), 0)

    if requestedLiters <= IPS_Util.EPSILON then
        return 0
    end

    local oldGross = IPS_Util.computeGross(price, oldLiters, invoiceClass)
    local requestedGross = IPS_Util.computeGross(price, oldLiters + requestedLiters, invoiceClass)
    if requestedGross - oldGross <= availableMoney then
        return requestedLiters
    end

    local low = 0
    local high = requestedLiters
    for _ = 1, 52 do
        local middle = (low + high) * 0.5
        local middleGross = IPS_Util.computeGross(price, oldLiters + middle, invoiceClass)
        if middleGross - oldGross <= availableMoney then
            low = middle
        else
            high = middle
        end
    end

    if low <= IPS_Util.EPSILON then
        return 0
    end
    return math.min(low, requestedLiters)
end

---Builds a persistent offer key.
-- @param string productionUniqueId Placeable unique identifier
-- @param integer fillTypeIndex Fill type identifier
-- @return string Offer key
function IPS_Util.makeOfferKey(productionUniqueId, fillTypeIndex)
    return string.format("%s:%d", tostring(productionUniqueId or ""), tonumber(fillTypeIndex) or 0)
end

---Builds a stable aggregation key for an invoice line.
-- @param string productionUniqueId Placeable unique identifier
-- @param integer fillTypeIndex Fill type identifier
-- @param number price Price per 1000 liters
-- @param number vatRate VAT rate as fraction
-- @return string Group key
function IPS_Util.makeLineKey(productionUniqueId, fillTypeIndex, price, vatRate)
    return string.format("%s:%d:%.9f:%.9f", tostring(productionUniqueId or ""), tonumber(fillTypeIndex) or 0, price or 0, vatRate or 0)
end

---Copies an array without sharing its container.
-- @param table? values Source array
-- @return table Copy
function IPS_Util.copyArray(values)
    local result = {}
    for index, value in ipairs(values or {}) do
        result[index] = value
    end
    return result
end
