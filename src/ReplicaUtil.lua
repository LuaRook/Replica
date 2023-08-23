--[[
    Author: @LuaRook
    Created: 8/11/2023
]]

--[ Dependencies ]--

local Signal = require(script.Parent.Parent.Signal)
local SharedTypes = require(script.Parent.SharedTypes)

--[ Types ]--

type Signal = Signal.Signal
type Connection = Signal.Connection
type PathListener = SharedTypes.PathListener

--[ Root ]--

local ReplicaUtil: { [string]: () -> () } = {}

--[ Variables ]--

local Listeners: { [string]: { [string]: Connection } } = {}

--[ Local Functions ]--

local function stringToArray(str: string): Path
	return string.split(str, ".")
end

--[ API ]--

-- Handles firing of listeners on the context the function is called.
--@param replicaId string The ID of the Replica being updated.
--@param listenerType string The type of listener being updated.
--@param path string The path being updated.
function ReplicaUtil.fireListener(replicaId: string, listenerType: string, path: string, ...)
	local replicaSignals = Listeners[replicaId]
	if not replicaSignals then
		return
	end

	-- Get signal types for listener type
	local typeSignals: { [string]: Signal } = replicaSignals[listenerType]
	if not typeSignals then
		return
	end

	-- Get signal for path
	local signal: Signal? = typeSignals[path]
	if not signal then
		return
	end

	-- Fire signal for current context
	signal:Fire(...)

	-- Clear references
	replicaSignals = nil
	typeSignals = nil
	signal = nil
end

-- Creates listener for context the function was called on.
--@param replicaId The ID of the replica the listener is for.
--@param listenerType string The type of listener being created.
--@param path string The path to listen to changes for.
--@param listener PathListener The function called whenever a path is updated.
--@return Connection
function ReplicaUtil.createListener(
	replicaId: string,
	listenerType: string,
	path: string,
	listener: PathListener
): Connection
	-- Create replica signal cache
	if not Listeners[replicaId] then
		Listeners[replicaId] = {}
	end

	-- Create listener cache for replica
	if not Listeners[replicaId][listenerType] then
		Listeners[replicaId][listenerType] = {}
	end

	-- Create signal if it doesn't exist
	if not Listeners[replicaId][listenerType][path] then
		Listeners[replicaId][listenerType][path] = Signal.new()
	end

	-- Connect listener
	return Listeners[replicaId][listenerType][path]:Connect(listener)
end

-- Clears listeners for the given replica.
--@param replicaId string The Id of the Replica to clear listeners for.
function ReplicaUtil.removeListeners(replicaId: string)
	-- Get listeners for replica
	local replicaListeners = Listeners[replicaId]
	if not replicaListeners then
		return
	end

	-- Destroy and disconnect all signal connections to prevent
	-- memory leaks.
	for _, data: { [string]: Signal } in replicaListeners do
		for _, signal: Signal in data do
			signal:Destroy()
		end
	end

	-- Prevent memory leaks by clearing listeners and removing reference.
	table.clear(replicaListeners)
	replicaListeners = nil
	Listeners[replicaId] = nil
end

-- Gets data pointer from path.
--@param path string The path of the data.
--@param data table A reference to the replicas data.
function ReplicaUtil.getPointer(path: string | { string }, data: { any }): { any }?
	-- Convert path to array
	if typeof(path) == "string" then
		path = stringToArray(path)
	end

	local pointer: { any } = data
	for _, entry: string in ipairs(path) do
		if not pointer then
			warn(`[Replica]: Entry "{entry}" is not a valid member of replica hierarchy.`)
			break
		end

		pointer = pointer[entry]
	end

	-- Clear references
	path = nil
	data = nil
	return pointer
end

-- Gets parent pointer of the specified path.
--@param path string The path of the data.
--@param data table A reference to the replicas data.
---@return table, string
function ReplicaUtil.getParent(path: string, data: { any }): ({ any }?, string?)
	-- Get path array
	path = stringToArray(path)

	-- Add guard against one-deep changes
	if #path <= 1 then
		path = nil
		return data
	end

	-- Get final entry and remove it from table
	local finalEntry: string = path[#path]
	table.remove(path, #path)

	local pointer: { any } = ReplicaUtil.getPointer(path, data)
	path = nil
	data = nil
	return pointer, finalEntry
end

--[ Return ]--

return ReplicaUtil
