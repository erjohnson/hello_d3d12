package hello_d3d12

import "core:fmt"
import "core:log"

import "jo/app"

main :: proc() {
	fmt.println("Hello Direct3D 12!")

	context.logger = log.create_console_logger(.Debug, {.Terminal_Color, .Level})

	app.init(title = "Hello Direct3D 12", fullscreen = .Off)
	for app.running() {
		if app.key_pressed(.Escape) do return
	}
}
