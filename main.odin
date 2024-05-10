// D3D12 triangle sample
//
// credits:
// - https://gist.github.com/karl-zylinski/e1d1d0925ac5db0f12e4837435c5bbfb
// - https://gist.github.com/jakubtomsu/ecd83e61976d974c7730f9d7ad3e1fd0

package hello_d3d12

import "core:fmt"
import "core:log"
import "core:mem"
import "core:sys/windows"
import "core:os"

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"

import "jo/app"

NUM_RENDERTARGETS :: 2

main :: proc() {
	fmt.println("Hello Direct3D 12!")

	context.logger = log.create_console_logger(.Debug, {.Terminal_Color, .Level})

	app.init(title = "Hello Direct3D 12", fullscreen = .Off)

	// Grab native window handle
	native_window := dxgi.HWND(app.window())

	hr: d3d12.HRESULT

    // Init factory
    factory: ^dxgi.IFactory4

	{
		flags: dxgi.CREATE_FACTORY

		when ODIN_DEBUG {
			flags |= dxgi.CREATE_FACTORY_DEBUG
		}

		hr = dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, cast(^rawptr)&factory)
		check_hr(hr, "Failed to create factory")
	}

	// Enumerate adapters
	adapter: ^dxgi.IAdapter1
	error_not_found := dxgi.HRESULT(-142213123)

	for i: u32 = 0; factory->EnumAdapters1(i, &adapter) != error_not_found; i += 1 {
		desc: dxgi.ADAPTER_DESC1
		adapter->GetDesc1(&desc)
		if dxgi.ADAPTER_FLAG.SOFTWARE not_in desc.Flags {
			continue
		}

		if d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._12_0, dxgi.IDevice_UUID, nil) >= 0 {
			break
		} else {
			fmt.println("Failed to create device")
		}
	}

	if adapter == nil {
		fmt.println("Could not find hardware adapter")
		return
	}

	// Create device
	device: ^d3d12.IDevice
	hr = d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._12_0, d3d12.IDevice_UUID, (^rawptr)(&device))
	check_hr(hr, "Failed to create device")
	queue: ^d3d12.ICommandQueue

	{
		desc := d3d12.COMMAND_QUEUE_DESC {
			Type = .DIRECT,
		}

		hr = device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&queue))
		check_hr(hr, "Failed to create command queue")
	}

	// Create swapchain
	swapchain: ^dxgi.ISwapChain3

	{
		desc := dxgi.SWAP_CHAIN_DESC1 {
			Width = u32(app.width()),
			Height = u32(app.height()),
			Format = .R8G8B8A8_UNORM,
			SampleDesc = {
				Count = 1,
				Quality = 0,
			},
			BufferUsage = {.RENDER_TARGET_OUTPUT},
			BufferCount = NUM_RENDERTARGETS,
			Scaling = .NONE,
			SwapEffect = .FLIP_DISCARD,
			AlphaMode = .UNSPECIFIED,
		}

		hr = factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(queue), native_window, &desc, nil, nil, (^^dxgi.ISwapChain1)(&swapchain))
		check_hr(hr, "Failed to create swap chain")
	}

	frame_index := swapchain->GetCurrentBackBufferIndex()

	rtv_descriptor_heap: ^d3d12.IDescriptorHeap

	{
		desc := d3d12.DESCRIPTOR_HEAP_DESC {
			NumDescriptors = NUM_RENDERTARGETS,
			Type = .RTV,
			Flags = {},
		}

		hr = device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&rtv_descriptor_heap))
		check_hr(hr, "Failed to create descriptor heap")
	}

	targets: [NUM_RENDERTARGETS]^d3d12.IResource

	{
		rtv_descriptor_size: u32 = device->GetDescriptorHandleIncrementSize(.RTV)

		rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
		rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

		for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
			hr = swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&targets[i]))
			check_hr(hr, "Failed to get render target")
			device->CreateRenderTargetView(targets[i], nil, rtv_descriptor_handle)
			rtv_descriptor_handle.ptr += uint(rtv_descriptor_size)
		}
	}

    command_allocator: ^d3d12.ICommandAllocator
    hr = device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&command_allocator))
    check_hr(hr, "Failed to create command allocator")

	root_signature: ^d3d12.IRootSignature

	{
		desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
			Version = ._1_0,
		}

		desc.Desc_1_0.Flags = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
		serialized_desc: ^d3d12.IBlob
		hr = d3d12.SerializeVersionedRootSignature(&desc, &serialized_desc, nil)
		check_hr(hr, "Failed to serialize root signature")
		hr = device->CreateRootSignature(0, serialized_desc->GetBufferPointer(), serialized_desc->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&root_signature))
		check_hr(hr, "Failed to create root signature")
		serialized_desc->Release()
	}

	pipeline: ^d3d12.IPipelineState

	{
		// Compile vertex and pixel shaders
		data :cstring=
			`struct PSInput {
				float4 position : SV_POSITION;
				float4 color : COLOR;
				};
				PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0) {
				PSInput result;
				result.position = position;
				result.color = color;
				return result;
				}
				float4 PSMain(PSInput input) : SV_TARGET {
				return input.color;
			};`

		data_size: uint = len(data)

		compile_flags: u32 = 0
		when ODIN_DEBUG {
			compile_flags |= u32(d3dc.D3DCOMPILE.DEBUG)
			compile_flags |= u32(d3dc.D3DCOMPILE.SKIP_OPTIMIZATION)
		}

		vs: ^d3d12.IBlob = nil
		ps: ^d3d12.IBlob = nil

		hr = d3dc.Compile(rawptr(data), data_size, nil, nil, nil, "VSMain", "vs_4_0", compile_flags, 0, &vs, nil)
		check_hr(hr, "Failed to compile vertex shader")

		hr = d3dc.Compile(rawptr(data), data_size, nil, nil, nil, "PSMain", "ps_4_0", compile_flags, 0, &ps, nil)
		check_hr(hr, "Failed to compile pixel shader")

		// This layout matches the vertices data defined further down
		vertex_format: []d3d12.INPUT_ELEMENT_DESC = {
			{
				SemanticName = "POSITION",
				Format = .R32G32B32_FLOAT,
				InputSlotClass = .PER_VERTEX_DATA,
			},
			{
				SemanticName = "COLOR",
				Format = .R32G32B32A32_FLOAT,
				AlignedByteOffset = size_of(f32) * 3,
				InputSlotClass = .PER_VERTEX_DATA,
			},
		}

		default_blend_state := d3d12.RENDER_TARGET_BLEND_DESC {
			BlendEnable = false,
			LogicOpEnable = false,

			SrcBlend = .ONE,
			DestBlend = .ZERO,
			BlendOp = .ADD,

			SrcBlendAlpha = .ONE,
			DestBlendAlpha = .ZERO,
			BlendOpAlpha = .ADD,

			LogicOp = .NOOP,
			RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
		}

		pipeline_state_desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC {
			pRootSignature = root_signature,
			VS = {
				pShaderBytecode = vs->GetBufferPointer(),
				BytecodeLength = vs->GetBufferSize(),
			},
			PS = {
				pShaderBytecode = ps->GetBufferPointer(),
				BytecodeLength = ps->GetBufferSize(),
			},
			StreamOutput = {},
			BlendState = {
				AlphaToCoverageEnable = false,
				IndependentBlendEnable = false,
				RenderTarget = { 0 = default_blend_state, 1..<7 = {} },
			},
			SampleMask = 0xFFFFFFFF,
			RasterizerState = {
				FillMode = .SOLID,
				CullMode = .BACK,
				FrontCounterClockwise = false,
				DepthBias = 0,
				DepthBiasClamp = 0,
				SlopeScaledDepthBias = 0,
				DepthClipEnable = true,
				MultisampleEnable = false,
				AntialiasedLineEnable = false,
				ForcedSampleCount = 0,
				ConservativeRaster = .OFF,
			},
			DepthStencilState = {
				DepthEnable = false,
				StencilEnable = false,
			},
			InputLayout = {
				pInputElementDescs = &vertex_format[0],
				NumElements = u32(len(vertex_format)),
			},
			PrimitiveTopologyType = .TRIANGLE,
			NumRenderTargets = 1,
			RTVFormats = { 0 = .R8G8B8A8_UNORM, 1..<7 = .UNKNOWN },
			DSVFormat = .UNKNOWN,
			SampleDesc = {
				Count = 1,
				Quality = 0,
			},
		}

		hr = device->CreateGraphicsPipelineState(&pipeline_state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&pipeline))
		check_hr(hr, "Pipeline creation failed")

		vs->Release()
		ps->Release()
	}

    // Create the commandlist that is reused further down.
    cmdlist: ^d3d12.IGraphicsCommandList
    hr = device->CreateCommandList(0, .DIRECT, command_allocator, pipeline, d3d12.ICommandList_UUID, (^rawptr)(&cmdlist))
    check_hr(hr, "Failed to create command list")
    hr = cmdlist->Close()
    check_hr(hr, "Failed to close command list")

    vertex_buffer: ^d3d12.IResource
    vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW

	{
		vertices := [?]f32 {
		    // pos            color
		     0.0 , 0.5, 0.0,  1,0,0,0,
		     0.5, -0.5, 0.0,  0,1,0,0,
		    -0.5, -0.5, 0.0,  0,0,1,0,
		}

		heap_props := d3d12.HEAP_PROPERTIES {
			Type = .UPLOAD,
		}

		vertex_buffer_size := len(vertices) * size_of(vertices[0])

		resource_desc := d3d12.RESOURCE_DESC {
			Dimension = .BUFFER,
			Alignment = 0,
			Width = u64(vertex_buffer_size),
			Height = 1,
			DepthOrArraySize = 1,
			MipLevels = 1,
			Format = .UNKNOWN,
			SampleDesc = { Count = 1, Quality = 0 },
			Layout = .ROW_MAJOR,
			Flags = {},
		}

		hr = device->CreateCommittedResource(&heap_props, {}, &resource_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&vertex_buffer))
		check_hr(hr, "Failed to create vertex buffer")

		gpu_data: rawptr
		read_range: d3d12.RANGE

		hr = vertex_buffer->Map(0, &read_range, &gpu_data)
		check_hr(hr, "Failed to create vertex buffer resource")

		mem.copy(gpu_data, &vertices[0], vertex_buffer_size)
		vertex_buffer->Unmap(0, nil)

	    vertex_buffer_view = d3d12.VERTEX_BUFFER_VIEW {
	        BufferLocation = vertex_buffer->GetGPUVirtualAddress(),
	        StrideInBytes = u32(vertex_buffer_size/3),
	        SizeInBytes = u32(vertex_buffer_size),
	    }
	}

	// This fence is used to wait for frames to finish
	fence_value: u64
	fence: ^d3d12.IFence
	fence_event: windows.HANDLE

	{
	    hr = device->CreateFence(fence_value, {}, d3d12.IFence_UUID, (^rawptr)(&fence))
	    check_hr(hr, "Failed to create fence")
	    fence_value += 1
	    manual_reset: windows.BOOL = false
	    initial_state: windows.BOOL = false
	    fence_event = windows.CreateEventW(nil, manual_reset, initial_state, nil)
	    if fence_event == nil {
	        fmt.println("Failed to create fence event")
	        return
	    }
	}

	for app.running() {
		if app.key_pressed(.Escape) do return

		hr = command_allocator->Reset()
		check_hr(hr, "Failed resetting command allocator")

		hr = cmdlist->Reset(command_allocator, pipeline)
		check_hr(hr, "Failed to reset command list")

		viewport := d3d12.VIEWPORT {
			Width = f32(app.width()),
			Height = f32(app.height()),
		}

		scissor_rect := d3d12.RECT {
			left = 0, right = i32(app.width()),
			top = 0, bottom = i32(app.height()),
		}

		// This state is reset everytime the cmd list is reset, so we need to rebind it
		cmdlist->SetGraphicsRootSignature(root_signature)
		cmdlist->RSSetViewports(1, &viewport)
		cmdlist->RSSetScissorRects(1, &scissor_rect)

		to_render_target_barrier := d3d12.RESOURCE_BARRIER {
			Type = .TRANSITION,
			Flags = {},
		}

		to_render_target_barrier.Transition = {
			pResource = targets[frame_index],
			StateBefore = d3d12.RESOURCE_STATE_PRESENT,
			StateAfter = {.RENDER_TARGET},
			Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
		}

		cmdlist->ResourceBarrier(1, &to_render_target_barrier)

		rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
		rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

		if (frame_index > 0) {
			s := device->GetDescriptorHandleIncrementSize(.RTV)
			rtv_handle.ptr += uint(frame_index * s)
		}

		cmdlist->OMSetRenderTargets(1, &rtv_handle, false, nil)

		// clear backbuffer
		clearcolor := [?]f32 { 0.05, 0.05, 0.05, 1.0 }
		cmdlist->ClearRenderTargetView(rtv_handle, &clearcolor, 0, nil)

		// draw call
		cmdlist->IASetPrimitiveTopology(.TRIANGLELIST)
		cmdlist->IASetVertexBuffers(0, 1, &vertex_buffer_view)
		cmdlist->DrawInstanced(3, 1, 0, 0)

		to_present_barrier := to_render_target_barrier
		to_present_barrier.Transition.StateBefore = {.RENDER_TARGET}
		to_present_barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT

		cmdlist->ResourceBarrier(1, &to_present_barrier)

		hr = cmdlist->Close()
		check_hr(hr, "Failed to close command list")

		// execute
		cmdlists := [?]^d3d12.IGraphicsCommandList { cmdlist }
		queue->ExecuteCommandLists(len(cmdlists), (^^d3d12.ICommandList)(&cmdlists[0]))

		// present
		{
			flags: dxgi.PRESENT
			params: dxgi.PRESENT_PARAMETERS
			hr = swapchain->Present1(1, flags, &params)
			check_hr(hr, "Present failed")
		}

		// wait for frame to finish
		{
			current_fence_value := fence_value

			hr = queue->Signal(fence, current_fence_value)
			check_hr(hr, "Failed to signal fence")

			fence_value += 1
			completed := fence->GetCompletedValue()

			if completed < current_fence_value {
				hr = fence->SetEventOnCompletion(current_fence_value, fence_event)
				check_hr(hr, "Failed to set event on completion flag")
				windows.WaitForSingleObject(fence_event, windows.INFINITE)
			}

			frame_index = swapchain->GetCurrentBackBufferIndex()
		}

	}
}

check_hr :: proc(res: d3d12.HRESULT, message: string) {
	if (res >= 0) {
		return
	}

	fmt.printf("%v. Error code: %0x\n", message, u32(res))
	os.exit(-1)
}
