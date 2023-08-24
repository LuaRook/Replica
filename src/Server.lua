--[[
    Author: @LuaRook
    Created: 8/11/2023
]]

--[ Dependencies ]--

local Net = require(script.Parent.Parent.Net)
local Trove = require(script.Parent.Parent.Trove)
local Timer = require(script.Parent.Parent.Timer)
local ReplicaUtil = require(script.Parent.ReplicaUtil)
local SharedTypes = require(script.Parent.SharedTypes)

--[ Roblox Services ]--

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

--[ Types ]--

export type Replica = SharedTypes.Replica
type ReplicaParams = SharedTypes.ReplicaParams
type PathListener = SharedTypes.PathListener
type Path = SharedTypes.Path

--[ Constants ]--

local UPDATE_RATE: number = 0.25

--[ Object References ]--

local CreationRemote = Net:RemoteEvent("ReplicaCreated")
local ChildRemote = Net:RemoteEvent("ReplicaChildren")
local DestroyRemote = Net:RemoteEvent("ReplicaDestroyed")
local ListenerRemote = Net:RemoteEvent("ReplicaListeners")
local MockRemote = Net:RemoteEvent("ReplicaMockRemote")

--[ Variables ]--

local DestroyedReplicas: { string } = {}

--[ Local Functions ]--

local function fireForPlayers(players: { Player }, ...)
	for _, player: Player in players do
		CreationRemote:FireClient(player, ...)
	end
end

--[ Class ]--

local ServerReplica = {}
ServerReplica.__index = ServerReplica

function ServerReplica.new(params: ReplicaParams)
	local self = setmetatable({}, ServerReplica)
	self._trove = Trove.new()
	self._queue = {}

	self.ChildQueue = {}
	self.Children = {}

	-- Populate class with replica data from parameters
	if params and typeof(params) == "table" then
		-- Setup replica Id. This is monkeypatching, but this is also the
		-- easiest way to go about doing this.
		params.ReplicaId = HttpService:GenerateGUID(false)

		for key, value in pairs(params) do
			self[key] = value
		end
	end

	self._trove:Add(function()
		-- Destroy and disconnect all signals on replica destroyed
		ReplicaUtil.removeListeners(self.ReplicaId)

		-- Insert replica into destruction queue
		table.insert(DestroyedReplicas, self.ReplicaId)
	end)

	-- Handle replica replication
	local replication: { Player } | string = params.Replication
	local replicateAll: boolean = not replication or replication == "All"
	if replicateAll then
		-- Provide replica parameters to new players
		self._trove:Connect(Players.PlayerAdded, function(player: Player)
			CreationRemote:FireClient(player, params)
			ChildRemote:FireClient(player, self.ReplicaId, self.Children)
		end)

		-- Fire replica creation remote for all players
		CreationRemote:FireAllClients(params)
	else
		-- Replicate replica to provided players
		fireForPlayers(replication, params)
	end

	-- Provide client with children
	self._trove:Add(Timer.Simple(UPDATE_RATE, function()
		-- Only fire remote whenever there are children in the queue
		if #self.ChildQueue > 0 then
			if replicateAll then
				ChildRemote:FireAllClients(self.ReplicaId, self.ChildQueue)
			else
				fireForPlayers(replication, self.ReplicaId, self.ChildQueue)
			end

			-- Insert children in queue into server queue
			for _, child: string in self.ChildQueue do
				self:_fireListener("ChildAdded", "Root", self)
				table.insert(self.Children, child)
			end

			-- Clear queue
			table.clear(self.ChildQueue)
		end
	end))

	return self
end

-- Returns JSON-encoded class
--@return string
function ServerReplica:Identify()
	return HttpService:JSONEncode(self)
end

-- Sets parent of replica.
--@param replica Replica
function ServerReplica:SetParent(replica: Replica)
	-- Prevent `nil` cases
	if not replica then
		return
	end

	-- Insert replica into child queue
	local replicaId: string = self.ReplicaId
	table.insert(replica.ChildQueue, replicaId)

	-- Remove replica from parent children
	self._trove:Add(function()
		local index: number? = table.find(replica.Children, replicaId)
		if index then
			table.remove(replica.Children, index)
		end
	end)

	-- Destroy on parent destroyed
	replica:AddCleanupTask(self)
end

-- Sets value from path.
--@param path string The path to update.
--@param value any The value to update the path to.
function ServerReplica:SetValue(path: string, value: any)
	-- Get data pointer
	local parentPointer, lastKey = ReplicaUtil.getParent(path, self.Data)
	local stringKey: string = string.gsub(path, `.{lastKey}`, "")
	local oldValue: any = parentPointer[lastKey]

	-- Update data
	if parentPointer and lastKey then
		-- Fire new key listeners
		if not parentPointer[lastKey] then
			self:_fireListener("NewKey", stringKey, value, lastKey)
		end

		parentPointer[lastKey] = value
		self:_fireListener("Change", path, value, oldValue)
	end

	-- Clear references
	parentPointer = nil
	lastKey = nil
	oldValue = nil
end

-- Sets values from path.
--@param path string The path to update.
--@param values table A dictionary of values to update.
function ServerReplica:SetValues(path: string, values: { [string]: any })
	-- Get data pointer
	local pointer = ReplicaUtil.getPointer(path, self.Data)

	-- Update data
	if pointer then
		-- Update values
		for key: string, value: any in values do
			-- Fire new key signal
			local oldValue: any = pointer[key]
			if not oldValue then
				self:_fireListener("NewKey", path, value, key)
			end

			pointer[key] = value
			self:_fireListener("Change", `{path}.{key}`, value, oldValue)
		end
	end

	-- Clear reference to pointer
	pointer = nil
end

-- Inserts value into array found at the specified path.
--@param path string The path of the array to update.
--@param value any The value to insert into the path array.
function ServerReplica:ArrayInsert(path: string, value: any): number
	-- Get data pointer
	local pointer = ReplicaUtil.getPointer(path, self.Data)

	-- Add entry to data
	if pointer then
		table.insert(pointer, value)
		self:_fireListener("ArrayInsert", path, value)
	end

	-- Return index or zero
	return if pointer then #pointer else 0
end

-- Sets index of array found at the specified path.
--@param path string The path of the array to update.
---@param index number The index to update in the specified table.
--@param value any The value to set the index to.
function ServerReplica:ArraySet(path: string, index: number, value: any): number
	-- Get data pointer
	local pointer = ReplicaUtil.getPointer(path, self.Data)

	-- Add entry to data
	if pointer and pointer[index] ~= nil then
		pointer[index] = value
		self:_fireListener("ArraySet", path, index, value)
	end

	-- Remove reference
	pointer = nil

	-- Return index
	return index
end

-- Removes index from array found at the specified path.
--@param path string The path of the array to update.
--@param index number The index to remove from the array.
function ServerReplica:ArrayRemove(path: string, index: number): any
	-- Get data pointer
	local pointer = ReplicaUtil.getPointer(path, self.Data)

	-- Remove entry from data
	local removedValue: any
	if pointer then
		removedValue = table.remove(pointer, index)
		self:_fireListener("ArrayRemove", path, index, removedValue)
	end

	-- Clear references
	pointer = nil

	-- Return removed value
	return removedValue
end

-- Fires specified arguments to the specified client
function ServerReplica:FireClient(player: Player, ...)
	-- Fire remote
	MockRemote:FireClient(player, self.ReplicaId, ...)
end

function ServerReplica:FireAllClients(...)
	if not self.Replication or self.Replication == "All" then
		MockRemote:FireAllClients(self.ReplicaId, ...)
	else
		-- Fire remote for players in replication
		for _, player: Player in self.Replication do
			MockRemote:FireClient(player, self.ReplicaId, ...)
		end
	end
end

-- Functions similarly to ``OnServerEvent``
--@param listener function
function ServerReplica:ConnectOnServerEvent(listener: (player: Player, any) -> ())
	return self._trove:Add(Net:Connect("ReplicaMockRemote", function(player: Player, replicaId: string, ...: any)
		-- Check if replica ID is the same
		if replicaId == self.ReplicaId then
			-- If player isn't apart of replication, return
			if self.Replication and self.Replication ~= "All" and not table.find(self.Replication, player) then
				return
			end

			task.spawn(listener, player, ...)
		end
	end))
end

-- Listens for children being added to the replica.
--@param listener PathListener The function to call when a child is added to the replica.
function ServerReplica:ListenToChildAdded(listener: (child: Replica) -> ()): RBXScriptConnection
	return self:_createListener("ChildAdded", "Root", listener)
end

-- Listens to all changes
--@param listener function
function ServerReplica:ListenToRaw(listener: (listenerType: string, path: { string }, any) -> ()): RBXScriptConnection
	return self:_createListener("Raw", "Root", listener)
end

-- Listens to changes from `SetValue`.
--@param path string The path to listen to changes to.
--@param listener PathListener The function to call when the path is updated.
function ServerReplica:ListenToChange(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("Change", path, listener)
end

-- Listens to new keys being added to the specified path.
--@param path string The path to listen for new keys in.
--@param listener PathListener The function to call when a new key is added.
function ServerReplica:ListenToNewKey(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("NewKey", path, listener)
end

-- Listens to keys changed at the specified path.
--@param path string The path to listen to changes in.
--@param listener PathListener The function to call when a key is changed.
function ServerReplica:ListenToKeyChanged(path: string, listener: PathListener)
	return self:ListenToRaw(function(listenerType: string, changedPath: { string }, newValue: any, oldValue: any)
		if listenerType == "Change" and changedPath:sub(1, #path) == path then
			task.spawn(listener, newValue, oldValue)
		end
	end)
end

-- Listens to changes from `ArrayInsert`.
--@param path string The path to listen to changes to.
--@param listener PathListener The function to call when the path is updated.
function ServerReplica:ListenToArrayInsert(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("ArrayInsert", path, listener)
end

-- Listens to changes from `ArraySet`.
--@param path string The path to listen to changes to.
--@param listener PathListener The function to call when the path is updated.
function ServerReplica:ListenToArraySet(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("ArraySet", path, listener)
end

-- Listens to changes from `ArrayRemove`.
--@param path string The path to listen to changes to.
--@param listener PathListener The function to call when the path is updated.
function ServerReplica:ListenToArrayRemove(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("ArrayRemove", path, listener)
end

-- Adds task to replica cleanup.
--@param task any Task to add to replica cleanup.
function ServerReplica:AddCleanupTask(task: any): any
	return self._trove:Add(task)
end

-- Removes task from replica cleanup.
--@param task any The task to remove from replica cleanup.
function ServerReplica:RemoveCleanupTask(task: any): any
	self._trove:Remove(task)
end

-- Wrapper for creating listeners.
--@param listenerType string The category for the listener.
--@param path string The path for the listener.
--@param listener function The listener to call when the path changes.
--@return RBXScriptConnection
function ServerReplica:_createListener(listenerType: string, path: string, listener: PathListener): RBXScriptConnection
	local connection = ReplicaUtil.createListener(self.ReplicaId, listenerType, path, listener)
	return self._trove:Add(connection)
end

function ServerReplica:_fireListener(listenerType: string, path: string, ...)
	-- Handle serverside listeners
	ReplicaUtil.fireListener(self.ReplicaId, listenerType, path, ...)

	-- Replicate to client
	local replication: { any } | string = self.Replication
	local arguments = { self.ReplicaId, listenerType, path, ... }

	if not replication or replication == "All" then
		ListenerRemote:FireAllClients(table.unpack(arguments))
	else
		fireForPlayers(replication, table.unpack(arguments))
	end
end

function ServerReplica:Destroy()
	self._trove:Destroy()
end

--- Destroys the replica for the specified player(s)
function ServerReplica:DestroyFor(...: Player)
	-- Loop through provided players
	for _, player: Player in { ... } do
		-- Check if provided player is a player
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			continue
		end

		-- Fire remote for player
		self:Destroy()
		DestroyRemote:FireClient(player, {
			self.ReplicaId,
		})
	end
end

--[ Initialization ]--

-- Setup replica destruction queue
do
	Timer.Simple(UPDATE_RATE, function()
		-- Only fire destruction remote if replicas destroyed is above zero
		if #DestroyedReplicas > 0 then
			DestroyRemote:FireAllClients(DestroyedReplicas)

			-- Clear table
			table.clear(DestroyedReplicas)
		end
	end)
end

--[ Return ]--

return ServerReplica
