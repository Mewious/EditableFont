export type ObjectParams = {
	[string | number]: any,
}

local function Create(objectType: string, objectParams: ObjectParams): Instance
	local object = Instance.new(objectType)
	local parent = objectParams.Parent
	objectParams.Parent = nil

	for name, value in objectParams do
		if name == "Attributes" then
			for attributeName, attributeValue in value do
				object:SetAttribute(attributeName, attributeValue)
			end
		elseif name == "Children" then
			for _, child in value do
				child.Parent = object
			end
		elseif typeof(value) == "Instance" then
			value.Parent = object
		else
			object[name] = value
		end
	end

	object.Parent = parent
	return object
end

return Create
