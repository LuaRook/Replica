--[[
    Author: @LuaRook
    Created: 8/11/2023
]]

--[ Dependencies ]--

local Trove = require(script.Parent.Parent.Trove)
local Signal = require(script.Parent.Parent.Signal)
local Net = require(script.Parent.Parent.Net)
local ReplicaUtil = require(script.Parent.ReplicaUtil)
local SharedTypes = require(script.Parent.SharedTypes)

--[ Roblox Services ]--

local HttpService = game:GetService("HttpService")

--[ Types ]--

export type Replica = SharedTypes.Replica
type ReplicaParams = SharedTypes.ReplicaParams
type ReplicaListener = SharedTypes.ReplicaListener
type PathListener = SharedTypes.PathListener

--[ Root ]--

local ClientReplica = {}
ClientReplica.__index = ClientReplica

ClientReplica.ReplicaCreated = Signal.new()

--[ Variables ]--

local Replicas: { [string]: Replica } = {}

--[ API ]--

function ClientReplica.RequestData() ---@deprecated
	warn(`This function has been deprecated! Please remove all references to it. Trace stack:\n\n{debug.traceback()}`)
end

-- Fires the specified callback when a replica of the specified classname is created.
--@param className string The required classname of the created replica.
--@param listener function The function that is called whenever a replica is created.
--@return RBXScriptConnection
function ClientReplica.ReplicaOfClassCreated(className: string, listener: ReplicaListener): RBXScriptConnection
	-- Call listeners with existing replicas
	for _, replica: Replica in Replicas do
		if replica.ClassName == className then
			task.spawn(listener, replica)
		end
	end

	return ClientReplica.ReplicaCreated:Connect(function(replica: Replica)
		-- If replica has the same class/token, call listener.
		if replica.ClassName == className then
			listener(replica)
		end
	end)
end

function ClientReplica.new(params)
	local self = setmetatable({}, ClientReplica)
	self._trove = Trove.new()
	self.ClassName = params.ClassName
	self.Children = {}
	self.ReplicaId = params.ReplicaId
	self.Data = params.Data
	self.Tags = params.Tags

	-- Handle cleanup
	self._trove:Add(function()
		-- Destroy and disconnect all signals on replica destroyed
		ReplicaUtil.removeListeners(self.ReplicaId)

		-- Remove replica from cache
		Replicas[self.ReplicaId] = self
	end)

	-- Fire creation signal
	ClientReplica.ReplicaCreated:Fire(self)
	return self
end

-- Returns JSON-encoded class
--@return string
function ClientReplica:Identify()
	return HttpService:JSONEncode(self)
end


-- Fires passed arguments to server
function ClientReplica:FireServer(...: any)
	-- Get remote
	local remote: RemoteEvent = Net:RemoteEvent("ReplicaMockRemote")

	-- Fires remote if it exists
	if remote then
		remote:FireServer(self.ReplicaId, ...)
	end
end

-- Functions similarly to ``OnClientEvent``
--@param listener function
function ClientReplica:ConnectOnClientEvent(listener: (params: ReplicaParams, any) -> ())
	return self._trove:Add(Net:Connect("ReplicaMockRemote", function(replicaId: string, ...: any)
		-- Check if replica ID is the same
		if replicaId == self.ReplicaId then
			task.spawn(listener, ...)
		end
	end))
end

-- Listens for children being added to the replica.
--@param listener PathListener The function to call when a child is added to the replica.
function ClientReplica:ListenToChildAdded(listener: (child: Replica) -> ()): RBXScriptConnection
	return self:_createListener("ChildAdded", "Root", listener)
end

-- Listens to all changes
--@param listener function
function ClientReplica:ListenToRaw(listener: (listenerType: string, path: { string }, any) -> ()): RBXScriptConnection
	return self:_createListener("Raw", "Root", listener)
end

-- Listens to changes from `SetValue`.
--@param path string The path to listen to changes to.
--@param listener PathListener The function to call when the path is updated.
function ClientReplica:ListenToChange(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("Change", path, listener)
end

-- Listens to new keys being added to the specified path.
--@param path string The path to listen for new keys in.
--@param listener PathListener The function to call when a new key is added.
function ClientReplica:ListenToNewKey(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("NewKey", path, listener)
end

-- Listens to keys changed at the specified path.
--@param path string The path to listen to changes in.
--@param listener PathListener The function to call when a key is changed.
function ClientReplica:ListenToKeyChanged(path: string, listener: PathListener)
	return self:ListenToRaw(function(listenerType: string, changedPath: { string }, newValue: any, oldValue: any)
		if listenerType == "Change" and changedPath:sub(1, #path) == path then
			task.spawn(listener, newValue, oldValue)
		end
	end)
end

-- Listens to changes from `ArrayInsert`.
--@param path string The path to listen to changes to.
--@param listener PathListener The function to call when the path is updated.
function ClientReplica:ListenToArrayInsert(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("ArrayInsert", path, listener)
end

-- Listens to changes from `ArraySet`.
--@param path string The path to listen to changes to.
--@param listener PathListener The function to call when the path is updated.
function ClientReplica:ListenToArraySet(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("ArraySet", path, listener)
end

-- Listens to changes from `ArrayRemove`.
--@param path string The path to listen to changes to.
--@param listener PathListener The function to call when the path is updated.
function ClientReplica:ListenToArrayRemove(path: string, listener: PathListener): RBXScriptConnection
	return self:_createListener("ArrayRemove", path, listener)
end

-- Adds task to replica cleanup.
--@param task any Task to add to replica cleanup.
function ClientReplica:AddCleanupTask(task: any): any
	return self._trove:Add(task)
end

-- Removes task from replica cleanup.
--@param task any The task to remove from replica cleanup.
function ClientReplica:RemoveCleanupTask(task: any): any
	self._trove:Remove(task)
end

-- Wrapper for creating listeners.
--@param listenerType string The category for the listener.
--@param path string The path for the listener.
--@param listener function The listener to call when the path changes.
--@return RBXScriptConnection
function ClientReplica:_createListener(listenerType: string, path: string, listener: PathListener): RBXScriptConnection
	local connection = ReplicaUtil.createListener(self.ReplicaId, listenerType, path, listener)
	return self._trove:Add(connection)
end

function ClientReplica:_fireListener(listenerType: string, path: string, ...)
	ReplicaUtil.fireListener(self.ReplicaId, listenerType, path, ...)
end

--[ Listener Handlers ]--

function ClientReplica:_onChildAdded(_: string, serverReplica: Replica)
	local clientReplica: Replica = Replicas[serverReplica.ReplicaId]
	if clientReplica then
		self:_fireListener("ChildAdded", "Root", clientReplica)
	end
end

function ClientReplica:_onChange(path: string, value: any)
	-- Get data pointer
	local parentPointer, lastKey = ReplicaUtil.getParent(path, self.Data)
	local oldValue: any = parentPointer[lastKey]

	-- Update data
	if parentPointer and lastKey then
		parentPointer[lastKey] = value
		self:_fireListener("Change", path, value, oldValue)
	end

	-- Remove references
	oldValue = nil
	parentPointer = nil
	lastKey = nil
end

function ClientReplica:_onNewKey(path: string, value: any, key: string)
	-- Fire listener for new key added
	self:_fireListener("NewKey", path, value, key)
end

function ClientReplica:_onArrayInsert(path: string, value: any): number
	-- Get data pointer
	local pointer = ReplicaUtil.getPointer(path, self.Data)

	-- Add entry to data
	if pointer then
		table.insert(pointer, value)
		self:_fireListener("ArrayInsert", path, #pointer, value)
	end
end

function ClientReplica:_onArraySet(path: string, index: number, value: any): number
	-- Get data pointer
	local pointer = ReplicaUtil.getPointer(path, self.Data)

	-- Add entry to data
	if pointer and pointer[index] ~= nil then
		pointer[index] = value
		self:_fireListener("ArraySet", path, index, value)
	end

	-- Remove reference
	pointer = nil
end

function ClientReplica:_onArrayRemove(path: string, index: number): any
	-- Get data pointer
	local pointer = ReplicaUtil.getPointer(path, self.Data)

	-- Remove entry from data
	if pointer then
		local removedValue: any = table.remove(pointer, index)
		self:_fireListener("ArrayRemove", path, index, removedValue)
	end

	-- Remove references
	pointer = nil
end

function ClientReplica:Destroy()
	self._trove:Destroy()
end

--[ Initialization ]--

do
	-- Connect to replica creation
	Net:Connect("ReplicaCreated", function(params)
		-- Create and cache replica
		Replicas[params.ReplicaId] = ClientReplica.new(params)
	end)

	-- Connect to child added
	Net:Connect("ReplicaChildren", function(replicaId: string, children: { Replica })
		-- Get parent replica
		local parentReplica: Replica = Replicas[replicaId]
		if not parentReplica then
			return
		end

		-- Set parent variable for provided replicas
		for _, childId: string in children do
			local childReplica: Replica = Replicas[childId]
			if not childReplica then
				continue
			end

			-- Cache replica in parent
			table.insert(parentReplica.Children, childReplica)
			childReplica:AddCleanupTask(function()
				local index: number = table.find(parentReplica.Children, childReplica)
				if index then
					table.remove(parentReplica.Children, index)
				end
			end)

			-- Add child to parent replica trove
			parentReplica:AddCleanupTask(childReplica)
		end
	end)

	-- Connect to replica destroyed
	Net:Connect("ReplicaDestroyed", function(destroyedReplicas: { string })
		for _, replicaId: string in destroyedReplicas do
			task.spawn(function()
				-- Get replica from ID
				local replica: Replica? = Replicas[replicaId]
				if not replica then
					return
				end

				-- Remove all references to replica
				replica:Destroy()
				replica = nil
				Replicas[replicaId] = nil
			end)
		end
	end)

	-- Connect to replica listeners
	Net:Connect("ReplicaListeners", function(replicaId: string, methodName: string, ...)
		local replica: Replica = Replicas[replicaId]
		if not replica then
			return
		end

		-- Update replica
		local method: () -> ()? = replica[`_on{methodName}`]
		if method then
			task.spawn(method, replica, ...)
		end

		-- Clear references
		replica = nil
		method = nil
	end)
end

--[ Return ]--

return ClientReplica
