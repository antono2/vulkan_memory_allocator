import json
import os
import time

struct SetupProfile {
	modules map[string]string
}

struct SetupFixture {
	work         string
	modules      string
	log          string
	original_env map[string]string
}

fn new_setup_fixture() SetupFixture {
	work := os.join_path(os.temp_dir(),
		'allocator setup with spaces ${os.getpid()} ${time.sys_mono_now()}')
	modules := os.join_path(work, 'modules')
	log := os.join_path(work, 'commands.jsonl')
	setup := os.join_path(modules, 'antono2', 'vulkan', 'setup.vsh')
	os.mkdir_all(os.dir(setup)) or { panic(err) }
	os.write_file(setup, '// Native setup is intercepted by the fixture CLI.\n') or { panic(err) }
	fake_source := os.join_path(work, 'fake_v.v')
	os.write_file(fake_source, 'module main
import json
import os
fn main() {
 mut log := os.open_append(os.getenv("SETUP_COMMAND_LOG")) or { panic(err) }
 defer { log.close() }
 log.writeln(json.encode(os.args[1..])) or { panic(err) }
}
') or {
		panic(err)
	}
	fake_cli := os.join_path(work, $if windows { 'v.exe' } $else { 'v' })
	compile :=
		os.execute('${os.quoted_path(@VEXE)} -o ${os.quoted_path(fake_cli)} ${os.quoted_path(fake_source)}')
	assert compile.exit_code == 0, compile.output
	fixture := SetupFixture{work, modules, log, os.environ()}
	os.setenv('VMODULES', modules, true)
	os.setenv('SETUP_COMMAND_LOG', log, true)
	os.setenv('V_C_ERROR_BUG_REPORT_DISABLED', '1', true)
	os.setenv('PATH', work + os.path_delimiter + os.getenv('PATH'), true)
	return fixture
}

fn (fixture SetupFixture) close() {
	for name in ['VMODULES', 'SETUP_COMMAND_LOG', 'V_C_ERROR_BUG_REPORT_DISABLED', 'PATH'] {
		if name in fixture.original_env {
			os.setenv(name, fixture.original_env[name], true)
		} else {
			os.unsetenv(name)
		}
	}
	os.rmdir_all(fixture.work) or { panic(err) }
}

fn (fixture SetupFixture) run_setup(arguments string, expected int) [][]string {
	result := os.execute('${os.quoted_path(@VEXE)} run ${os.quoted_path(os.join_path(@VMODROOT,
		'setup.vsh'))} ${arguments}')
	assert result.exit_code == expected, result.output
	mut commands := [][]string{}
	if os.is_file(fixture.log) {
		for line in os.read_lines(fixture.log) or { panic(err) } {
			commands << json.decode([]string, line) or { panic(err) }
		}
	}
	return commands
}

fn test_setup_install_uses_declared_dependency_versions() {
	fixture := new_setup_fixture()
	defer { fixture.close() }
	commands := fixture.run_setup('--install', 0)
	profile := json.decode(SetupProfile, os.read_file(os.join_path(@VMODROOT, 'compatibility.json')) or {
		panic(err)
	}) or { panic(err) }
	installs := commands.filter(it[0] == 'install').map(it[1])
	assert installs == ['antono2.vulkan@${profile.modules['vulkan']}',
		'antono2.memory@${profile.modules['memory']}', 'antono2.vkmemalloc']
	assert commands[1] == ['run', os.join_path(fixture.modules, 'antono2', 'vulkan', 'setup.vsh'),
		'--install']
	assert commands.last() == ['test', @VMODROOT]
}

fn test_setup_check_performs_no_installs() {
	fixture := new_setup_fixture()
	defer { fixture.close() }
	assert fixture.run_setup('--check', 0) == [
		['run', os.join_path(fixture.modules, 'antono2', 'vulkan', 'setup.vsh'), '--check'],
		['test', @VMODROOT],
	]
}

fn test_setup_invalid_option_performs_no_commands() {
	fixture := new_setup_fixture()
	defer { fixture.close() }
	assert fixture.run_setup('--unknown', 2) == [][]string{}
}
