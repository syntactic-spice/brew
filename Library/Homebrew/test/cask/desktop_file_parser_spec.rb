# typed: true
# frozen_string_literal: true

require "cask/desktop_file_parser"

RSpec.describe Cask::DesktopFileParser do
  subject(:desktop_file) { described_class.new(contents) }

  let(:contents) do
    <<~'EOS'
      # A comment
      [Desktop Entry]
      Type=Application
      Name = Foo
      Name[de]=Foo DE
      Exec=foo %U
      Comment=Back\\slash and\sspace

      [Desktop Action new]
      Name=New
      Exec=foo --new
    EOS
  end

  describe ".split_exec" do
    it "splits quoted arguments" do
      expect(described_class.split_exec(%q(env A="b c" 'd e' f\ g %U))).to eq(["env", "A=b c", "d e", "f g", "%U"])
    end

    it "raises on unmatched quotes" do
      expect { described_class.split_exec('foo "bar') }.to raise_error(ArgumentError)
    end
  end

  describe ".join_exec" do
    it "quotes only arguments with reserved characters" do
      expect(described_class.join_exec(["/A/foo", "--flag", "%U", "A=b c"])).to eq('/A/foo --flag %U "A=b c"')
    end

    it "escapes characters with a special meaning inside quotes" do
      expect(described_class.join_exec(['a "b" $c \\d'])).to eq('"a \\"b\\" \\$c \\\\d"')
    end
  end

  describe ".replace_exec_program" do
    subject(:replaced_exec) do
      described_class.replace_exec_program(exec, program:, environment:)
    end

    let(:exec) { "" }
    let(:program) { "/A/Foo.AppImage" }
    let(:environment) { { "X" => "1" } }

    describe "when it sets variables with `env`" do
      let(:exec) { "env GDK_BACKEND=x11 UBUNTU_MENUPROXY=0 audacity %F" }

      it "keeps them" do
        expect(replaced_exec).to eq("env X=1 GDK_BACKEND=x11 UBUNTU_MENUPROXY=0 /A/Foo.AppImage %F")
      end
    end

    describe "when it sets variables without `env`" do
      let(:exec) { "LD_LIBRARY_PATH=usr/lib clashmi %u" }

      it "sets them with `env`" do
        expect(replaced_exec).to eq("env X=1 LD_LIBRARY_PATH=usr/lib /A/Foo.AppImage %u")
      end
    end

    describe "when it runs a program with arguments" do
      let(:exec) { "AppRun --no-sandbox %U" }

      it "keeps the arguments" do
        expect(replaced_exec).to eq("env X=1 /A/Foo.AppImage --no-sandbox %U")
      end
    end

    describe "when its program is double-quoted" do
      let(:exec) { '"Shutter Encoder"' }

      it "replaces the whole program" do
        expect(replaced_exec).to eq("env X=1 /A/Foo.AppImage")
      end
    end

    describe "when its program is single-quoted" do
      let(:exec) { "'Foo Bar' --flag %U" }

      it "replaces the whole program" do
        expect(replaced_exec).to eq("env X=1 /A/Foo.AppImage --flag %U")
      end
    end

    describe "when it sets a variable from the environment among others" do
      let(:exec) { "env FOO=1 X=0 BAR=2 AppRun %U" }

      it "replaces only that variable" do
        expect(replaced_exec).to eq("env X=1 FOO=1 BAR=2 /A/Foo.AppImage %U")
      end
    end

    describe "when it sets quoted values" do
      let(:exec) { 'env FOO="a \"b\" c" AppRun "%f"' }

      it "quotes only what needs it" do
        expect(replaced_exec).to eq('env X=1 "FOO=a \"b\" c" /A/Foo.AppImage %f')
      end
    end

    describe "when the program has reserved characters" do
      let(:program) { "/A/My $Apps/Foo%.AppImage" }

      it "quotes it and escapes its percent sign" do
        expect(replaced_exec).to eq('env X=1 "/A/My \$Apps/Foo%%.AppImage"')
      end
    end

    describe "when there are no variables to set" do
      let(:exec) { "AppRun %U" }
      let(:environment) { {} }

      it "doesn't use `env`" do
        expect(replaced_exec).to eq("/A/Foo.AppImage %U")
      end
    end

    describe "when it has an unmatched quote" do
      let(:exec) { 'AppRun "--flag' }

      it "raises" do
        expect { replaced_exec }.to raise_error(ArgumentError)
      end
    end

    describe "when it is empty" do
      it "runs the program" do
        expect(replaced_exec).to eq("env X=1 /A/Foo.AppImage")
      end
    end
  end

  describe "#desktop_entry?" do
    it "is true when the first group is `[Desktop Entry]`" do
      expect(desktop_file.desktop_entry?).to be(true)
    end

    describe "when another group comes first" do
      let(:contents) { "[Foo]\n[Desktop Entry]\n" }

      it "is false" do
        expect(desktop_file.desktop_entry?).to be(false)
      end
    end

    describe "when it is a binary" do
      let(:contents) { "\x7FELF\x02\x01\x01".b }

      it "is false" do
        expect(desktop_file.desktop_entry?).to be(false)
      end
    end
  end

  describe "#groups" do
    it "lists the groups in order" do
      expect(desktop_file.groups).to eq(["Desktop Entry", "Desktop Action new"])
    end

    describe "when a group is repeated" do
      let(:contents) { "[Desktop Entry]\n[Desktop Action new]\n[Desktop Action new]\n" }

      it "lists it once" do
        expect(desktop_file.groups).to eq(["Desktop Entry", "Desktop Action new"])
      end
    end
  end

  describe "#get" do
    it "ignores spaces around `=`" do
      expect(desktop_file.get("Name")).to eq("Foo")
    end

    it "reads localised keys separately" do
      expect(desktop_file.get("Name[de]")).to eq("Foo DE")
    end

    it "resolves escape sequences" do
      expect(desktop_file.get("Comment")).to eq("Back\\slash and space")
    end

    it "reads from the given group" do
      expect(desktop_file.get("Exec", group: "Desktop Action new")).to eq("foo --new")
    end

    it "returns nil for a missing key" do
      expect(desktop_file.get("Icon")).to be_nil
    end
  end

  describe "#set" do
    it "replaces an existing key in place" do
      desktop_file.set("Exec", "bar", group: "Desktop Action new")

      expect(desktop_file.to_s).to eq(contents.sub("Exec=foo --new", "Exec=bar"))
    end

    it "adds a missing key at the end of its group" do
      desktop_file.set("Icon", "/A/foo.png")

      expect(desktop_file.to_s).to eq(contents.sub("and\\sspace\n", "and\\sspace\nIcon=/A/foo.png\n"))
    end

    it "escapes the value" do
      desktop_file.set("Comment", "a\\b\nc")

      expect(desktop_file.to_s).to include("Comment=a\\\\b\\nc\n")
    end

    it "raises for a missing group" do
      expect { desktop_file.set("Name", "Foo", group: "Missing") }.to raise_error(ArgumentError)
    end
  end

  describe "#delete" do
    it "removes the key from its group only" do
      desktop_file.delete("Exec")

      expect(desktop_file.to_s).to eq(contents.sub("Exec=foo %U\n", ""))
    end
  end

  describe "#to_s" do
    it "keeps comments and layout" do
      expect(desktop_file.to_s).to eq(contents)
    end
  end
end
