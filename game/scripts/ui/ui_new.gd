extends CanvasLayer

@onready var steel = $Label
@onready var coin = $Label2

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	steel.text = "Steel: " + str(Global.Steel)
	coin.text = "Coin: " + str(Global.Coin)
