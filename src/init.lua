--[[
    Author: @LuaRook
    Created: 8/4/2023
]]

--[ Roblox Services ]--

local RunService = game:GetService("RunService")

--[ Return Class ]--

return if RunService:IsServer() then require(script.Server) else require(script:WaitForChild("Client"))
