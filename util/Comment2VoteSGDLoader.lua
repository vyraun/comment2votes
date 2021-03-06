local Comment2VoteSGDLoader = {}
Comment2VoteSGDLoader.__index = Comment2VoteSGDLoader

function Comment2VoteSGDLoader.create(data_dir, batch_size, split_fractions)
	local self = {}
	setmetatable(self, Comment2VoteSGDLoader)

	local comment_file = path.join(data_dir, 'comments.txt')
	local score_file = path.join(data_dir, 'scores.txt')
	local vocab_file = path.join(data_dir, 'vocab.t7')
	local tensor_comment_file = path.join(data_dir, 'comments.t7')
	local tensor_score_file = path.join(data_dir, 'scores.t7')

	local run_prepro = false
	if not (path.exists(vocab_file) or path.exists(tensor_comment_file) or path.exists(tensor_score_file)) then
	    print('vocab.t7, comment.t7, scores.t7 files do not exist. Running preprocessing...')
	    run_prepro = true
	else
	    local comment_attr = lfs.attributes(comment_file)
	    local score_attr = lfs.attributes(score_file)
	    local tensor_attr = lfs.attributes(vocab_file)
	    if comment_attr.modification > tensor_attr.modification or score_attr.modification > tensor_attr.modification then
	        print('t7 files detected as stale. Re-running preprocessing...')
	        run_prepro = true
	    end
	end

	if run_prepro then
		print('one-time setup: processing files ' .. comment_file .. ' and ' .. score_file)
		Comment2VoteSGDLoader.data_to_tensor(comment_file, score_file, vocab_file, tensor_comment_file, tensor_score_file)
	end

	print('loading files...')
	self.comments = torch.load(tensor_comment_file)
	self.scores = torch.load(tensor_score_file)
	self.vocab_mapping = torch.load(vocab_file)

	self.vocab_size = 0
	for _ in pairs(self.vocab_mapping) do
		self.vocab_size = self.vocab_size + 1
	end

	self.num_comments = 0
	for _ in pairs(self.comments) do 
		self.num_comments = self.num_comments + 1
	end
	self.batch_size = batch_size

	print('making even bathes...')
	if self.num_comments % batch_size ~= 0 then
		repeat 
			table.remove(self.comments, self.num_comments)
			table.remove(self.scores, self.num_comments)
			self.num_comments = self.num_comments - 1
		until self.num_comments % batch_size == 0
	end

	print('preparing batches...')
	self.batch_comments = {}
	self.batch_scores = {}
	-- total num batches
	self.nbatches = self.num_comments / self.batch_size
	for i=1, self.nbatches do
		local max_length = self.comments[i*batch_size]:nElement()
		local batch_comment = torch.ByteTensor(batch_size, max_length):fill(self.vocab_size+1)
		local batch_score = torch.DoubleTensor(batch_size, 1)
		for k=1, batch_size do
			local comment = self.comments[(i-1)*batch_size + k]
			local score = self.scores[(i-1)*batch_size + k]
			batch_comment:select(1, k):sub(1, comment:nElement()):copy(comment)
			batch_score:select(1, k):copy(score)
		end
		table.insert(self.batch_comments, batch_comment)
		table.insert(self.batch_scores, batch_score)
	end
	self.batch_list_perm = torch.randperm(#self.batch_comments)

	print('preparing splits sizes...')
	assert(split_fractions[1] >= 0 and split_fractions[1] <= 1, 'bad split fraction ' .. split_fractions[1] .. ' for train, not between 0 and 1')
	assert(split_fractions[2] >= 0 and split_fractions[2] <= 1, 'bad split fraction ' .. split_fractions[2] .. ' for val, not between 0 and 1')
	assert(split_fractions[3] >= 0 and split_fractions[3] <= 1, 'bad split fraction ' .. split_fractions[3] .. ' for test, not between 0 and 1')
	if split_fractions[3] == 0 then 
		-- catch a common special case where the user might not want a test set
		self.ntrain = math.floor(self.nbatches * split_fractions[1])
		self.nval = self.nbatches - self.ntrain
		self.ntest = 0
	else
	    -- divide data to train/val and allocate rest to test
		self.ntrain = math.floor(self.nbatches * split_fractions[1])
		self.nval = math.floor(self.nbatches * split_fractions[2])
		self.ntest = self.nbatches - self.nval - self.ntrain -- the rest goes to test (to ensure this adds up exactly)
	end

	self.split_sizes = {self.ntrain, self.nval, self.ntest}
	self.batch_ix = {0,0,0}

	collectgarbage()

	return self
end

function Comment2VoteSGDLoader:next_batch(split_index)
 	self.batch_ix[split_index] = self.batch_ix[split_index] + 1
 	-- wrap around 
 	if self.batch_ix[split_index] > self.split_sizes[split_index] then
 		self.batch_ix[split_index] = 1
 	end
 
 	local ix = self.batch_ix[split_index]
 	if split_index == 2 then ix = ix + self.ntrain end 
 	if split_index == 3 then ix = ix + self.ntrain + self.nval end
	return self.batch_comments[self.batch_list_perm[ix]], self.batch_scores[self.batch_list_perm[ix]]
end

function Comment2VoteSGDLoader:reset_batch_pointer(split_index)
	self.batch_ix[split_index] = 0
end

function Comment2VoteSGDLoader.data_to_tensor(comment_file, score_file, vocab_file, tensor_comment_file, tensor_score_file)

	local rawdata
	local num_comments = 0
	local tot_len = 0

	print('loading score file...')
	c = io.open(score_file)
	rawdata = c:read()
	repeat 
		num_comments = num_comments + 1
		rawdata = c:read()
	until not rawdata
	c:close()

	print('putting scores into tensor...')
	c = io.open(score_file, 'r')
	scores = torch.DoubleTensor(1, num_comments)
	for i=1,num_comments do
		scores[{{}, i}] = tonumber(c:read())
	end
	c:close()

	--normalize socres
	local mean = scores:mean()
	local std = scores:std()
	scores:add(-mean)
	scores:div(std)
	--local dbg=require("debugger"); dbg()

	print('loading comment file and creating vocabulary mapping...')

	local unordered = {}
	f = io.open(comment_file)
	for i=1, num_comments do
		rawdata = f:read()
		for char in rawdata:gmatch'.' do
		    if not unordered[char] then unordered[char] = true end
		end
		tot_len = tot_len + #rawdata
	end
	f:close()

	local ordered = {}
	for char in pairs(unordered) do ordered[#ordered + 1] = char end
	table.sort(ordered)
	
	local vocab_mapping = {}
	for i, char in ipairs(ordered) do
	    vocab_mapping[char] = i
	end

	print('putting comments into tensor...')
	comments = {}
	f = io.open(comment_file)
	for i=1,num_comments do
		rawdata = f:read()
		if #rawdata == 0 then
			num_comments = num_comments - 1
		else
			comment = torch.ByteTensor(1, #rawdata)
			for k=1,#rawdata do
				comment[{{}, k}] = vocab_mapping[rawdata:sub(k,k)]
			end
			table.insert(comments, {comment, scores[{{}, i}]})
		end
	end
	f:close()

	print('sorting comments...')
	table.sort(comments, compare)

	sorted_comments = {}
	sorted_scores = {}
	for i=1,num_comments do
		table.insert(sorted_comments, comments[i][1])
		table.insert(sorted_scores, comments[i][2])
	end

	print('saving ' .. vocab_file)
	torch.save(vocab_file, vocab_mapping)
	print('saving ' .. tensor_comment_file)
	torch.save(tensor_comment_file, sorted_comments)
	print('saving ' .. tensor_score_file)
	torch.save(tensor_score_file, sorted_scores)

end

function compare(a, b)
	return a[1]:nElement() < b[1]:nElement()
end

return Comment2VoteSGDLoader