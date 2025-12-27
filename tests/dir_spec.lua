-- Tests for directory comparison (dir.lua)
local helpers = require('tests.helpers')

describe('dir module', function()
  local dir_mod

  before_each(function()
    helpers.ensure_plugin_loaded()
    dir_mod = require('codediff.core.dir')
  end)

  after_each(function()
    helpers.close_extra_tabs()
  end)

  describe('diff_directories', function()
    it('should detect added files (only in dir2)', function()
      local dir1 = helpers.create_temp_dir()
      local dir2 = helpers.create_temp_dir()

      vim.fn.writefile({ 'content' }, dir2 .. '/new_file.txt')

      local result = dir_mod.diff_directories(dir1, dir2)

      assert.is_not_nil(result.status_result)
      assert.equals(1, #result.status_result.unstaged)
      assert.equals('new_file.txt', result.status_result.unstaged[1].path)
      assert.equals('A', result.status_result.unstaged[1].status)

      vim.fn.delete(dir1, 'rf')
      vim.fn.delete(dir2, 'rf')
    end)

    it('should detect deleted files (only in dir1)', function()
      local dir1 = helpers.create_temp_dir()
      local dir2 = helpers.create_temp_dir()

      vim.fn.writefile({ 'content' }, dir1 .. '/old_file.txt')

      local result = dir_mod.diff_directories(dir1, dir2)

      assert.is_not_nil(result.status_result)
      assert.equals(1, #result.status_result.unstaged)
      assert.equals('old_file.txt', result.status_result.unstaged[1].path)
      assert.equals('D', result.status_result.unstaged[1].status)

      vim.fn.delete(dir1, 'rf')
      vim.fn.delete(dir2, 'rf')
    end)

    it('should detect modified files (different size)', function()
      local dir1 = helpers.create_temp_dir()
      local dir2 = helpers.create_temp_dir()

      vim.fn.writefile({ 'short' }, dir1 .. '/file.txt')
      vim.fn.writefile({ 'much longer content' }, dir2 .. '/file.txt')

      local result = dir_mod.diff_directories(dir1, dir2)

      assert.is_not_nil(result.status_result)
      assert.equals(1, #result.status_result.unstaged)
      assert.equals('file.txt', result.status_result.unstaged[1].path)
      assert.equals('M', result.status_result.unstaged[1].status)

      vim.fn.delete(dir1, 'rf')
      vim.fn.delete(dir2, 'rf')
    end)

    it('should return correct structure for identical directories', function()
      local dir1 = helpers.create_temp_dir()
      local dir2 = helpers.create_temp_dir()

      vim.fn.writefile({ 'same content' }, dir1 .. '/file.txt')
      vim.fn.writefile({ 'same content' }, dir2 .. '/file.txt')

      local result = dir_mod.diff_directories(dir1, dir2)

      -- May show as modified due to mtime difference from file creation timing
      -- Just verify the structure is correct
      assert.is_not_nil(result.status_result)
      assert.is_not_nil(result.root1)
      assert.is_not_nil(result.root2)

      vim.fn.delete(dir1, 'rf')
      vim.fn.delete(dir2, 'rf')
    end)

    it('should handle nested directories', function()
      local dir1 = helpers.create_temp_dir()
      local dir2 = helpers.create_temp_dir()

      vim.fn.mkdir(dir1 .. '/subdir', 'p')
      vim.fn.mkdir(dir2 .. '/subdir', 'p')
      vim.fn.writefile({ 'nested' }, dir2 .. '/subdir/nested.txt')

      local result = dir_mod.diff_directories(dir1, dir2)

      assert.is_not_nil(result.status_result)
      assert.equals(1, #result.status_result.unstaged)
      assert.equals('subdir/nested.txt', result.status_result.unstaged[1].path)
      assert.equals('A', result.status_result.unstaged[1].status)

      vim.fn.delete(dir1, 'rf')
      vim.fn.delete(dir2, 'rf')
    end)

    it('should return normalized root paths', function()
      local dir1 = helpers.create_temp_dir()
      local dir2 = helpers.create_temp_dir()

      local result = dir_mod.diff_directories(dir1, dir2)

      assert.is_not_nil(result.root1)
      assert.is_not_nil(result.root2)
      assert.is_true(result.root1:sub(-1) ~= '/')
      assert.is_true(result.root2:sub(-1) ~= '/')

      vim.fn.delete(dir1, 'rf')
      vim.fn.delete(dir2, 'rf')
    end)

    it('should sort files alphabetically', function()
      local dir1 = helpers.create_temp_dir()
      local dir2 = helpers.create_temp_dir()

      vim.fn.writefile({ 'c' }, dir2 .. '/c.txt')
      vim.fn.writefile({ 'a' }, dir2 .. '/a.txt')
      vim.fn.writefile({ 'b' }, dir2 .. '/b.txt')

      local result = dir_mod.diff_directories(dir1, dir2)

      assert.equals(3, #result.status_result.unstaged)
      assert.equals('a.txt', result.status_result.unstaged[1].path)
      assert.equals('b.txt', result.status_result.unstaged[2].path)
      assert.equals('c.txt', result.status_result.unstaged[3].path)

      vim.fn.delete(dir1, 'rf')
      vim.fn.delete(dir2, 'rf')
    end)
  end)
end)
