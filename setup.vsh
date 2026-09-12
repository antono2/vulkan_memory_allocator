#!/usr/bin/env -S v run

// Delegates native Vulkan preparation to antono2.vulkan, then installs and
// verifies the allocator module.
import os

fn run(command string) ! {
	println('\n> ${command}')
	result := os.execute(command)
	if result.output.trim_space() != '' {
		println(result.output.trim_right('\r\n'))
	}
	if result.exit_code != 0 {
		return error('command failed with exit code ${result.exit_code}')
	}
}

fn main() {
	if os.args.len > 2
		|| (os.args.len == 2 && os.args[1] !in ['--install', '--check', '-h', '--help']) {
		eprintln('Usage: v run setup.vsh [--install|--check]')
		exit(2)
	}
	if os.args.len == 2 && os.args[1] in ['-h', '--help'] {
		println('Usage: v run setup.vsh [--install|--check]\n\nDefault: install native Vulkan prerequisites and V modules.\n--check: perform read-only prerequisite and compile checks.')
		return
	}
	install := os.args.len == 1 || os.args[1] == '--install'
	if install {
		run('v install antono2.vulkan') or { panic(err) }
	}
	vulkan_setup := os.join_path(os.vmodules_dir(), 'antono2', 'vulkan', 'setup.vsh')
	if !os.is_file(vulkan_setup) {
		eprintln('antono2.vulkan does not include setup.vsh; update it with `v update antono2.vulkan`')
		exit(1)
	}
	mode := if install { '--install' } else { '--check' }
	run('v run ${os.quoted_path(vulkan_setup)} ${mode}') or { panic(err) }
	$if windows {
		vulkan_sdk :=
			os.execute('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable(\'VULKAN_SDK\', \'Machine\')"')
		if vulkan_sdk.exit_code == 0 && vulkan_sdk.output.trim_space() != '' {
			os.setenv('VULKAN_SDK', vulkan_sdk.output.trim_space(), true)
		}
	}
	if install {
		run('v install antono2.memory') or { panic(err) }
		run('v install antono2.vkmemalloc') or { panic(err) }
	}
	project_dir := os.dir(os.real_path(@FILE))
	run('v test ${os.quoted_path(project_dir)}') or { panic(err) }
	println('\nVulkan allocator prerequisites and compile checks are ready.')
}
