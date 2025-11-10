extends CanvasLayer

@onready var uranium = $Label
@onready var metal = $Label2

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	uranium.text = "Uranium: " + str(Global.Uranium)
	metal.text = "Metal: " + str(Global.Metal)
