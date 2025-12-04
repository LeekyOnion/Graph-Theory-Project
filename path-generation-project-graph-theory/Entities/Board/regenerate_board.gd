extends Control

@export var board : BoardManager # Ensure this is assigned in the Inspector

func _ready() -> void:
	pass

func _on_pressed() -> void:
	if board:
		board.cleanup_board()
		board.generate_board() 
	else:
		print("Cannot regenerate board: BoardManager reference is missing.")
