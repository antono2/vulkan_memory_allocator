// Run allocator compatibility, compiler, and GPU allocation checks.
import os

const allocation_examples = ['buffer_suballocation', 'image_suballocation', 'stress']
const icd_directory = '/usr/share/vulkan/icd.d'
const validation_layer = 'VK_LAYER_KHRONOS_validation'

fn checked(args []string) ! {
	result := os.exec(args)
	print(result.output)
	if result.exit_code != 0 {
		return error('${args.join(' ')} exited with status ${result.exit_code}.')
	}
}

fn compiler(args []string) ! {
	mut call := [@VEXE]
	call << args
	checked(call)!
}

fn env_required(name string) !string {
	value := os.getenv(name)
	if value == '' {
		return error('${name} is required for this CI stage.')
	}
	return value
}

fn compatibility() ! {
	for script in ['scripts/compatibility.vsh', 'scripts/doctor.vsh'] {
		compiler(['run', script, '--self-test'])!
	}
	compiler(['run', 'scripts/compatibility.vsh', '--github-output', env_required('GITHUB_OUTPUT')!])!
}

fn lavapipe(example string) ! {
	if example !in allocation_examples {
		return error('Unknown allocation example: ${example}.')
	}
	mut manifests := os.ls(icd_directory)!.filter(it.starts_with('lvp_icd') && it.ends_with('.json')
		&& os.is_file(os.join_path(icd_directory, it)))
	manifests.sort()
	if manifests.len == 0 {
		return error('No Lavapipe ICD manifest in ${icd_directory}.')
	}
	// A prior driver override takes precedence over VK_ICD_FILENAMES.
	os.unsetenv('VK_DRIVER_FILES')
	os.setenv('VK_ICD_FILENAMES', os.join_path(icd_directory, manifests[0]), true)
	compiler(['run', os.join_path('examples', example)])!
}

fn build_master() ! {
	directory := os.abs_path(os.join_path('toolchain', 'v'))
	checked(['make', '-C', directory, 'VEXE=./v'])!
	mut file := os.open_append(env_required('GITHUB_PATH')!)!
	defer { file.close() }
	file.writeln(directory)!
}

fn run(args []string) ! {
	os.unsetenv('VEXE')
	if args == ['build-master'] {
		build_master()!
		return
	}
	os.chdir(os.dir(@DIR))!
	match args {
		['compatibility'] {
			compatibility()!
		}
		['linux-tests'] {
			for cc in ['gcc', 'tcc'] {
				compiler(['-cc', cc, 'test', '.'])!
			}
		}
		['windows-tests'] {
			compiler(['-cc', 'msvc', 'test', '.'])!
			os.setenv('VK_INSTANCE_LAYERS', validation_layer, true)
			compiler(['-cc', 'msvc', 'run', 'examples/buffer_suballocation'])!
		}
		['master-tests'] {
			compiler(['run', 'scripts/test_setup.vsh'])!
			compiler(['-cc', 'gcc', 'test', '.'])!
		}
		else {
			if args.len != 2 || args[0] != 'lavapipe' {
				return error('Expected an allocator CI stage.')
			}
			lavapipe(args[1])!
		}
	}
}

run(os.args[1..]) or {
	eprintln(err)
	exit(1)
}
