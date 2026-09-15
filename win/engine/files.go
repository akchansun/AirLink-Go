package engine

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"huchuan/protocol"
)

type LocalFile struct {
	Path     string
	Rel      string
	Size     uint64
	Modified float64
}

func Collect(paths []string) ([]LocalFile, error) {
	var out []LocalFile
	for _, p := range paths {
		st, err := os.Stat(p)
		if err != nil {
			continue
		}
		if st.IsDir() {
			root := p
			_ = filepath.WalkDir(p, func(path string, d fs.DirEntry, err error) error {
				if err != nil {
					return nil
				}
				name := d.Name()
				if strings.HasPrefix(name, ".") {
					if d.IsDir() && path != root {
						return fs.SkipDir
					}
					return nil
				}
				if d.IsDir() {
					return nil
				}
				info, err := d.Info()
				if err != nil {
					return nil
				}
				rel, err := filepath.Rel(filepath.Dir(root), path)
				if err != nil {
					return nil
				}
				clean, ok := protocol.SanitizeRelativePath(filepath.ToSlash(rel))
				if !ok {
					return nil
				}
				out = append(out, LocalFile{
					Path:     path,
					Rel:      clean,
					Size:     uint64(info.Size()),
					Modified: float64(info.ModTime().UnixNano()) / 1e9,
				})
				return nil
			})
		} else {
			out = append(out, LocalFile{
				Path:     p,
				Rel:      protocol.SanitizeFileName(filepath.Base(p)),
				Size:     uint64(st.Size()),
				Modified: float64(st.ModTime().UnixNano()) / 1e9,
			})
		}
	}
	if len(out) == 0 {
		return nil, errMsg("没有可发送的文件")
	}
	if len(out) > MaxFilesOnce {
		return nil, errMsg("一次最多发送 2 万个文件，请拆开再传")
	}
	return out, nil
}

type errMsg string

func (e errMsg) Error() string { return string(e) }

func readAt(path string, offset uint64, count int) ([]byte, error) {
	if count <= 0 {
		return []byte{}, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, errMsg("无法打开文件：" + path)
	}
	defer f.Close()
	buf := make([]byte, count)
	n, err := f.ReadAt(buf, int64(offset))
	if n < 0 {
		n = 0
	}
	if n < count {
		buf = buf[:n]
	}
	if n == 0 && err != nil {
		return nil, errMsg("读文件失败")
	}
	return buf, nil
}

func createPart(path string, size uint64) (*os.File, error) {
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, errMsg("无法创建文件：" + path)
	}
	if err := f.Truncate(int64(size)); err != nil {
		f.Close()
		return nil, errMsg("磁盘空间不足")
	}
	return f, nil
}

func writeAt(f *os.File, offset uint64, data []byte) error {
	if len(data) == 0 {
		return nil
	}
	n, err := f.WriteAt(data, int64(offset))
	if err != nil || n != len(data) {
		return errMsg("写文件失败")
	}
	return nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func fileSize(path string) uint64 {
	st, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return uint64(st.Size())
}
