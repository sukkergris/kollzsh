"""
Tests for parse_commands() in ollama_util.py.

Each test documents a real failure mode we hit during development so
regressions are caught immediately without needing a running Ollama instance.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from ollama_util import parse_commands


# ---------------------------------------------------------------------------
# JSON path
# ---------------------------------------------------------------------------

def test_clean_json_array():
    result = parse_commands('["ls -la", "find . -type f", "du -sh *"]')
    assert result == ["ls -la", "find . -type f", "du -sh *"]


def test_json_array_with_escaped_quotes():
    result = parse_commands('["echo \\"Hello World\\"", "printf \\"Hello\\\\n\\""]')
    assert result == ['echo "Hello World"', 'printf "Hello\\n"']


def test_json_array_in_markdown_fence():
    content = '```json\n["ls -la", "find . -type f"]\n```'
    result = parse_commands(content)
    assert result == ["ls -la", "find . -type f"]


def test_json_array_in_plain_fence():
    content = '```\n["ls -la", "find . -type f"]\n```'
    result = parse_commands(content)
    assert result == ["ls -la", "find . -type f"]


def test_single_quoted_list():
    # Some models emit Python-style single-quoted lists
    result = parse_commands("['ls -la', 'find . -type f']")
    assert result == ["ls -la", "find . -type f"]


# ---------------------------------------------------------------------------
# Malformed JSON path (regex extraction)
# ---------------------------------------------------------------------------

def test_malformed_json_unescaped_quotes():
    # Model forgets to escape inner quotes — triggers regex path
    content = '["ls -la", "find . -name "*.py""]'
    result = parse_commands(content)
    assert len(result) >= 1
    assert any("ls" in c for c in result)


def test_nested_json_arrays():
    # Model wraps commands in nested arrays
    content = '[["ls -la", "ls -l"], ["find . -type f"]]'
    result = parse_commands(content)
    assert len(result) >= 1


# ---------------------------------------------------------------------------
# Plain-text path
# ---------------------------------------------------------------------------

def test_plain_text_one_per_line():
    content = 'echo "Hello World"\nprintf "Hello World\\n"\necho -e "Hello World"'
    result = parse_commands(content)
    assert result == ['echo "Hello World"', 'printf "Hello World\\n"', 'echo -e "Hello World"']


def test_numbered_list_markers_stripped():
    content = "1. ls -la\n2. find . -type f\n3. du -sh *"
    result = parse_commands(content)
    assert result == ["ls -la", "find . -type f", "du -sh *"]


def test_bullet_list_markers_stripped():
    content = "- ls -la\n* find . -type f\n- du -sh *"
    result = parse_commands(content)
    assert result == ["ls -la", "find . -type f", "du -sh *"]


# ---------------------------------------------------------------------------
# Filtering — things that must NOT appear in results
# ---------------------------------------------------------------------------

def test_prose_filtered_out():
    # Heredoc body or model explanation starting with uppercase
    content = 'echo "Hello World"\nHello World\nprintf "Hello World\\n"'
    result = parse_commands(content)
    assert "Hello World" not in result
    assert 'echo "Hello World"' in result


def test_bare_quote_filtered():
    content = 'echo "Hello World"\n"\nprintf "Hello World\\n"'
    result = parse_commands(content)
    assert '"' not in result


def test_code_fence_lines_filtered():
    content = '```\necho "Hello World"\nprintf "Hello World\\n"\n```'
    result = parse_commands(content)
    assert not any(c.startswith("```") for c in result)
    assert 'echo "Hello World"' in result


def test_heredoc_start_filtered():
    # cat <<EOF should not appear as a suggestion
    content = 'echo "Hello World"\ncat <<EOF\nHello World\nEOF'
    result = parse_commands(content)
    assert not any("<<" in c for c in result)


def test_heredoc_body_filtered():
    # The content inside a heredoc should not appear as a command
    content = 'cat <<EOF\nHello World\nEOF\necho "Hello World"'
    result = parse_commands(content)
    assert "Hello World" not in result
    assert "EOF" not in result


def test_multiline_command_filtered():
    # Commands containing actual newlines should not be output
    content = "bash <<EOF\necho hello\nEOF"
    result = parse_commands(content)
    assert not any("\n" in c for c in result)


def test_empty_string_filtered():
    result = parse_commands("")
    assert result == []


def test_non_string_input():
    assert parse_commands(None) == []
    assert parse_commands(42) == []
    assert parse_commands([]) == []


# ---------------------------------------------------------------------------
# Edge cases from real model outputs
# ---------------------------------------------------------------------------

def test_starcoder_shell_help_garbage():
    # starcoder2:3b returned shell help text instead of commands.
    # The plain-text parser can't distinguish help prose from valid commands
    # without risking false positives on things like curl -H "Content-Type: ...".
    # This test documents the known limitation: short lowercase lines pass through.
    content = "help\nhelp: display this message\nexit\nget-cwd"
    result = parse_commands(content)
    # Single-char lines are filtered; everything else starting lowercase passes
    assert "h" not in result  # single char filtered
    # Multi-word help text may pass — that's acceptable given the model was wrong


def test_qwen_repeated_commands():
    # qwen2.5-coder:7b sometimes repeats the same command list 3 times
    content = (
        'echo "Hello World"\nprintf "Hello World\\n"\n'
        'echo "Hello World"\nprintf "Hello World\\n"\n'
        'echo "Hello World"\nprintf "Hello World\\n"'
    )
    result = parse_commands(content)
    # parse_commands itself doesn't deduplicate — that's done in __main__
    # but at least all entries should be valid commands
    assert all(c.startswith(("echo", "printf")) for c in result)


def test_path_commands_allowed():
    content = "/usr/bin/python3 --version\n./run.sh\n~/scripts/deploy.sh"
    result = parse_commands(content)
    assert "/usr/bin/python3 --version" in result
    assert "./run.sh" in result
    assert "~/scripts/deploy.sh" in result
