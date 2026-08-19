module ark.ui;

import ark.style;
import ark.components;
import ark.structures;

import core.thread;
import std.algorithm;
import std.array;
import std.stdio;
import std.string;
import std.datetime;

version (Windows) {
	import core.sys.windows.windows;
	import core.sys.windows.wincon;
} else {
	import core.sys.posix.unistd;
	import core.sys.posix.termios;
}

mixin Structures!();

/** 
 * Terminal components.
 */
final class ArkTerm {
	private static immutable defaultLineLength = 50;
	private static bool colorEnabled = true;
	private static size_t spinnerIndex = 0;
	private static immutable string[] spinnerChars = [
		"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
	];

	private static BorderChars[BorderStyle] borderStyles;

	static this() {
		version (Windows)
			SetConsoleOutputCP(65_001);

		borderStyles = [
			BorderStyle.SINGLE: BorderChars("┌", "┐", "└", "─┘", "─", "│", "┬", "┴", "├", "┤", "┼"),
			BorderStyle.DOUBLE: BorderChars("╔", "╗", "╚", "╝", "═", "║", "╦", "╩", "╠", "╣", "╬"),
			BorderStyle.ROUNDED: BorderChars("╭", "╮", "╰", "─╯", "─", "│", "┬", "┴", "├", "┤", "┼"),
			BorderStyle.THICK: BorderChars("┏", "┓", "┗", "┛", "━", "┃", "┳", "┻", "┣", "┫", "╋"),
			BorderStyle.ASCII: BorderChars("+", "+", "+", "+", "-", "|", "+", "+", "+", "+", "+")
		];
	}

	mixin ArkStyle!();
	mixin ArkComponents!();

	static void clear() {
		version (Windows) {
			for (int i = 0; i < 100; i++) {
				writeln("\n");
			}
			HANDLE hConsole = GetStdHandle(
				STD_OUTPUT_HANDLE);
			CONSOLE_SCREEN_BUFFER_INFO csbi;

			if (!GetConsoleScreenBufferInfo(
					hConsole, &csbi)) {
				writeln("Failed to get console buffer info.");
				return;
			}

			SMALL_RECT scrollRect = csbi.srWindow;
			COORD destOrigin = COORD(0, cast(short)(csbi.srWindow.Top - 100));
			CHAR_INFO fill;
			fill.Char.AsciiChar = ' ';
			fill.Attributes = csbi
				.wAttributes;

			ScrollConsoleScreenBufferA(
				hConsole,
				&scrollRect,
				null,
				destOrigin,
				&fill
			);

			COORD topLeft = COORD(0, csbi
					.srWindow
					.Top);
			SetConsoleCursorPosition(hConsole, topLeft);
		}
		version (Posix) {
			writeln("\033[2J\033[H");
		}
	}

	static void log(LogLevel level, string message) {
		auto timestamp = Clock.currTime.toISOExtString()[0 .. 19];
		string levelStr;
		Color levelColor;

		final switch (level) {
		case LogLevel.INFO:
			levelStr = "INFO ";
			levelColor = Color.BLUE;
			break;
		case LogLevel.SUCCESS:
			levelStr = "OK   ";
			levelColor = Color.GREEN;
			break;
		case LogLevel.WARNING:
			levelStr = "WARN ";
			levelColor = Color.YELLOW;
			break;
		case LogLevel.ERROR:
			levelStr = "ERROR";
			levelColor = Color.RED;
			break;
		case LogLevel.DEBUG:
			levelStr = "DEBUG";
			levelColor = Color.MAGENTA;
			break;
		}

		writef("[%s] %s %s\n",
			colorize(timestamp, Color.BRIGHT_BLACK),
			colorize(levelStr, levelColor),
			message
		);
	}
}

/** 
 * Specifically for input-capturing TUIs.
 */
final class ArkTUI {
	version (Windows) {
		HANDLE hIn;
		DWORD originalMode;
	} else {
		termios origTerm;
	}

	this() {
		version (Windows)
			SetConsoleOutputCP(65_001);

		enableRawMode();
		write("\033[?25l");
	}

	~this() {
		disableRawMode();
		write("\033[?25h");
		write("\033[0m\033[2J\033[H");
	}

	void enableRawMode() {
		version (Windows) {
			hIn = GetStdHandle(STD_INPUT_HANDLE);
			DWORD mode;
			GetConsoleMode(hIn, &mode);
			originalMode = mode;
			mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT);
			SetConsoleMode(hIn, mode);
		} else {
			tcgetattr(0, &origTerm);
			termios raw = origTerm;
			raw.c_lflag &= ~(ICANON | ECHO);
			tcsetattr(0, TCSAFLUSH, &raw);
		}
	}

	void disableRawMode() {
		version (Windows)
			SetConsoleMode(hIn, originalMode);
		else
			tcsetattr(0, TCSAFLUSH, &origTerm);
	}

	char readKey() {
		char c;
		version (Windows) {
			DWORD read;
			ReadConsoleA(hIn, &c, 1, &read, null);
		} else {
			read(0, &c, 1);
		}
		return c;
	}

	void clear() {
		write("\033[2J\033[H");
	}

	void moveTo(int row, int col) {
		writef("\033[%d;%dH", row, col);
	}

	void drawBox(int x, int y, int w, int h, string title = "") {
		moveTo(y, x);
		write("┌" ~ "─".replicate(w - 2) ~ "┐");
		foreach (i; 1 .. h - 1) {
			moveTo(y + i, x);
			write("│" ~ " ".replicate(w - 2) ~ "│");
		}
		moveTo(y + h - 1, x);
		write("└" ~ "─".replicate(w - 2) ~ "┘");
		if (title.length > 0 && title.length < w - 4) {
			moveTo(y, x + 2);
			write(
				" " ~ title ~ " ");
		}
	}

	/** 
     * Draw a text input box that can be typed in.
     *
     * Params:
     *   prompt = Label for the input box
     *   defaultValue = Default text in the box
     *   width = Width of the input box
     *   secret = Whether to mask input with asterisks
     */
	static string getTextInput(
		string prompt = "",
		string defaultValue = "",
		size_t width = 40,
		bool secret = false
	) {
		import ark.style : ArkStyle;
		import std.conv : to;
		import std.string : strip;

		version (Windows) {
			import core.sys.windows.windows;
		} else {
			import core.sys.posix.termios;
		}

		string input = defaultValue;
		size_t cursorPos = input.length;

		version (Windows) {
			HANDLE hStdin = GetStdHandle(STD_INPUT_HANDLE);
			DWORD oldMode;
			GetConsoleMode(hStdin, &oldMode);
			SetConsoleMode(hStdin, oldMode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT));
		} else {
			termios oldTermios, newTermios;
			tcgetattr(0, &oldTermios);
			newTermios = oldTermios;
			newTermios.c_lflag &= ~(ICANON | ECHO);
			tcsetattr(0, TCSANOW, &newTermios);
		}

		scope (exit) {
			version (Windows)
				SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), oldMode);
			else
				tcsetattr(0, TCSANOW, &oldTermios);
		}

		if (prompt.length > 0)
			writeln(noConColorize(prompt, Color.CYAN));

		writeln(noConColorize("┌" ~ "─".replicate(width) ~ "┐", Color.WHITE));
		writeln(noConColorize("│" ~ " ".replicate(width) ~ "│", Color.WHITE));
		writeln(noConColorize("└" ~ "─".replicate(width) ~ "┘", Color.WHITE));

		void updateContent() {
			write("\033[2A\033[2G");
			write(" ".replicate(width));
			write("\033[" ~ width.to!string ~ "D");

			string displayText = secret && input.length > 0 ? "*".replicate(input.length) : input;
			if (displayText.length > width)
				displayText = displayText[0 .. width];

			if (cursorPos < displayText.length) {
				write(displayText[0 .. cursorPos]);
				write(noConColorize(displayText[cursorPos .. cursorPos + 1], Color.WHITE));
				write(displayText[cursorPos + 1 .. $]);
			} else {
				write(displayText);
				if (cursorPos == displayText.length && displayText.length < width)
					write(noConColorize("█", Color.WHITE));
			}

			write("\033[3B\033[1G");
			stdout.flush();
		}

		updateContent();

		while (true) {
			char ch;
			version (Windows) {
				DWORD dwRead;
				ReadConsoleA(GetStdHandle(STD_INPUT_HANDLE), &ch, 1, &dwRead, null);
			} else {
				read(0, &ch, 1);
			}

			if (ch == '\r' || ch == '\n') {
				write("\033[2B\033[0G");
				return input;
			} else if (ch == '\b' || ch == 127) {
				if (cursorPos > 0) {
					input = input[0 .. cursorPos - 1] ~ input[cursorPos .. $];
					cursorPos--;
					updateContent();
				}
			} else if (ch == 27) {
				version (Windows) {
					char ch2, ch3;
					DWORD dwReada;
					ReadConsoleA(GetStdHandle(STD_INPUT_HANDLE), &ch2, 1, &dwReada, null);
					if (ch2 == '[') {
						ReadConsoleA(GetStdHandle(STD_INPUT_HANDLE), &ch3, 1, &dwReada, null);
						if (ch3 == 'C' && cursorPos < input.length) {
							cursorPos++;
							updateContent();
						} else if (ch3 == 'D' && cursorPos > 0) {
							cursorPos--;
							updateContent();
						}
					}
				} else {
					char[2] seq;
					if (read(0, &seq[0], 1) == 1 && seq[0] == '[') {
						if (read(0, &seq[1], 1) == 1) {
							if (seq[1] == 'C' && cursorPos < input.length) {
								cursorPos++;
								updateContent();
							} else if (seq[1] == 'D' && cursorPos > 0) {
								cursorPos--;
								updateContent();
							}
						}
					}
				}
			} else if (ch == 3) {
				write("\033[2B\033[0G");
				throw new Exception("Cancelled");
			} else if (ch >= 32 && ch <= 126) {
				if (input.length < width - 1) {
					input = input[0 .. cursorPos] ~ ch ~ input[cursorPos .. $];
					cursorPos++;
					updateContent();
				}
			}
		}
	}

	int showMenu(string[] options, string title = "Select an option:") {
		int selected = 0;

		while (true) {
			clear();
			writeln(title);
			ArkTerm.drawSeparator("─", title.length);

			foreach (i, option; options) {
				if (i == selected)
					writeln(ArkTerm.colorize("> " ~ option, Color.CYAN));
				else
					writeln("  " ~ option);
			}

			char key = readKey();
			switch (key) {
			case 'w', 'W':
				selected = selected > 0 ? selected - 1 : cast(int) options.length - 1;
				break;
			case 's', 'S':
				selected = (selected + 1) % cast(int) options.length;
				break;
			case '\r', '\n':
				return selected;
			case 'q', 'Q', 27:
				return -1;
			default:
				break;
			}
		}
	}
}

unittest {
	class App {
		void run() {
			ArkTerm.log(LogLevel.INFO, "執行程式運行中...");

			ArkTerm.drawBreadcrumb([
					"家目錄",
					"項目",
					"我的",
					"源碼"
				]);

			writeln;

			ArkTerm.drawToast("Testing Message", LogLevel.SUCCESS);

			writeln;

			ArkTerm.drawAlert("系統資訊");
			string[][] sysInfo = [
				["OS", "CPU", "記憶體"],
				["Linux", "Intel i7", "16GB"],
				["作業系統", "佔用", "可用"],
				["Ubuntu 22.04", "45%", "8.8GB"]
			];

			size_t[] colWidths = [15, 12, 10, 8];

			ArkTerm.drawColumns(sysInfo, colWidths);

			writeln;

			ArkTerm.drawGauge(75, 0, 100, 25, "CPU 利用率", Color.YELLOW);
			ArkTerm.drawGauge(45, 0, 100, 25, "記憶體", Color.GREEN);
			ArkTerm.drawGauge(90, 0, 100, 25, "磁碟機", Color.RED);

			writeln;

			double[] cpuData = [
				23, 45, 67, 43, 89, 76, 54, 32, 67, 78, 45, 23, 56, 78, 90
			];

			ArkTerm.drawSparkline(cpuData, 30, "CPU Trend");

			writeln;

			ArkTerm.drawAlert("測試消息", LogLevel.SUCCESS);
			ArkTerm.drawKeyValue("版本", "1.0.0");
			ArkTerm.drawKeyValue("作者", "Acme");
			ArkTerm.drawKeyValue("構建", "Debug");

			writeln;

			write("加载数据: ");

			foreach (i; 0 .. 301) {
				ArkTerm.drawProgress(i / 200.0, 10, "", Color.GREEN);
				Thread.sleep(99.nsecs);
			}

			writeln;

			ArkTerm.drawStatus("核心狀態", true, "loaded in 245ms");
			ArkTerm.drawStatus("網路狀態", true, "connected");
			ArkTerm.drawStatus("數據庫狀態", false, "connection failed");

			writeln;

			string[] headers = [
				"名稱",
				"狀態",
				"CPU",
				"記憶體"
			];
			string[][] data = [
				[
					"網路伺服",
					"執行中",
					"12%",
					"256MB"
				],
				[
					"數據庫",
					"已停用",
					"0%",
					"0MB"
				],
				[
					"快取",
					"執行中",
					"3%",
					"128MB"
				]
			];

			ArkTerm.drawAlert("系統狀態:");
			ArkTerm.drawTable(headers, data);
			ArkTerm.drawTextBox(
				"這是一個具有自動換行功能多行文字框。它可以包含多個段落，並且會在指定的寬度限制內尝试格式化內容。\n" ~
					"這是一個具有自動換行功能多行文字框。它可以包含多個段落，並且會在指定的寬度限制內尝试格式化內容。\n",
					60, BorderStyle.ROUNDED, Color.BLUE, "资讯"
			);

			writeln;

			string sampleCode = `void main() {
    import std.stdio;
    writeln("Hello, World");
    
    foreach(i; 0..5) {
        writeln("Count: ", i);
    }
}`;
			ArkTerm.drawCodeBlock(sampleCode, "D");

			writeln;

			string[string] dashboardPanels = [
				"伺服器狀態": "在線\n在線時長: 24h 15m\n載入: 0.45",
				"數據庫": "已連接\n事務列隊/sec: 1,247\n連接數: 12/100",
				"快取": "Redis 在線\n命中率: 94.2%\n記憶體: 2.1GB",
				"網路": "速率: 45 Mbps\n延遲: 12ms\n丟包率: 0%"
			];

			ArkTerm.drawAlert("系統儀表板:");
			ArkTerm.drawDashboard(dashboardPanels, 2);
			ArkTerm.drawAlert("專案結構:");

			string[string] projectTree = [
				"src/main.d": "Main application file",
				"src/ui/terminal.d": "Terminal UI components",
				"src/core/app.d": "Core application logic",
				"tests/unit.d": "Unit tests",
				"docs/README.md": "Documentation"
			];

			string tree = ArkTerm.drawTree(
				projectTree, onlyReturn:
				true
			);

			ArkTerm.drawAlert(tree);

			writeln;

			ArkTerm.log(LogLevel.SUCCESS, "示範已成功完成");

			writeln;

			ArkTerm.drawBarChart(["測試", "消息", "放置"], [1, 10, 20]);

			writeln;

			double[] datax = [1.0, 2.5, 1.8, 3.2, 2.1, 4.0, 3.5];
			string[] labels = [
				"一月", "二月", "三月", "四月", "五月", "六月",
				"七月"
			];

			ArkTerm.drawLineGraph(datax, 60, 15, "月度銷售統計", labels, true, Color.GREEN);

			string[] categories = [
				"房租", "食物", "交通", "娛樂", "結餘存款"
			];
			double[] amounts = [1200, 400, 300, 200, 500];

			ArkTerm.drawPieChart(categories, amounts, 10, "Monthly Budget ($)", true);
			ArkTerm.drawBreakdownChart(
				["Ruby", "CSS", "JavaScript", "Other"],
				[50.0, 20.0, 15.0, 15.0],
				60,
				"Repo Language Breakdown"
			);

			ArkTerm.drawLineGraph(datax, 60, 15, "Monthly Sales", labels, true, Color.GREEN, scatter:
				true);

			FlowNode[] nodes = [
				FlowNode("start", "開始", 5, 2),
				FlowNode("process", "文檔處理", 5, 8),
				FlowNode("decision", "有效?", 5, 14),
				FlowNode("end", "結案", 25, 14)
			];

			FlowConnection[] connections = [
				FlowConnection("start", "process", "down"),
				FlowConnection("process", "decision", "down"),
				FlowConnection("decision", "end", "right")
			];

			ArkTerm.drawFlowDiagram(nodes, connections, 50, 20);
			ArkTerm.printColorized(Color.RED, Color.BLUE, "泥嚎");

			string[] headers2 = ["名稱", "年齡", "城市"];
			string[][] data2 = [
				["Alice", "25", "紐約"],
				["Bob", "30", "倫敦"],
				["Charlie", "35", "京東"]
			];
			ArkTerm.drawRoundedTable(headers2, data2);

			ArkTerm.drawBarChart(["測試", "數據", "放置在這"], [1, 10, 20], config:
				ArkTerm.ArkBarConfiguration([
						Color.BRIGHT_RED,
						Color.BLUE,
						Color.GRUVBOXRED
					]));

			string name = ArkTUI.getTextInput();

			writeln("You said: " ~ name);

		}
	}

	new App().run;
}
