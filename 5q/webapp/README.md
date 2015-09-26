## glossary

- permitted: `another_id == current_user[:id] || is_friend?(another_id)`
- is_friend:
  - `SELECT COUNT(1) AS cnt FROM relations WHERE (one = ? AND another = ?) OR (one = ? AND another = ?)`
  - resource_user_id, current_user_id
- mark_footprint:
  - if `user_id != owner_id` then
  - `INSERT INTO footprints (user_id,owner_id) VALUES (?,?)`

## request path

### GET /login

- セッションクリア
- 画面レンダリング

### POST /login

ログインチェックしてセッションに突っ込む

``` sql
SELECT u.id AS id, u.account_name AS account_name, u.nick_name AS nick_name, u.email AS email
FROM users u
JOIN salts s ON u.id = s.user_id
WHERE u.email = ? AND u.passhash = SHA2(CONCAT(?, s.salt), 512)
```

リダイレクトは `/` 固定

### GET /logout

### GET /

要求ログイン

``` sql
-- profile ----
SELECT * FROM profiles WHERE user_id = ? -- current_user[:id]

-- entries_query ----
SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5 -- current_user[:id]
-- .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }

-- comments_for_me ----
SELECT c.id AS id, c.entry_id AS entry_id, c.user_id AS user_id, c.comment AS comment, c.created_at AS created_at
FROM comments c
JOIN entries e ON c.entry_id = e.id
WHERE e.user_id = ?
ORDER BY c.created_at DESC
LIMIT 10 -- current_user[:id]

-- entries_of_friends ----
SELECT * FROM entries ORDER BY created_at DESC LIMIT 1000
-- next unless is_friend?(entry[:user_id])
-- entry[:title] = entry[:body].split(/\n/).first
-- entries_of_friends << entry
-- break if entries_of_friends.size >= 10

-- comments_of_friends ----
SELECT * FROM comments ORDER BY created_at DESC LIMIT 1000
-- next unless is_friend?(comment[:user_id])
SELECT * FROM entries WHERE id = ?' -- comment[:entry_id]
-- entry[:is_private] = (entry[:private] == 1)
-- next if entry[:is_private] && !permitted?(entry[:user_id])
-- comments_of_friends << comment
-- break if comments_of_friends.size >= 10

-- friends
SELECT * FROM relations WHERE one = ? OR another = ? ORDER BY created_at DESC -- current_user[:id], current_user[:id]

-- footprints
SELECT user_id, owner_id, DATE(created_at) AS date, MAX(created_at) AS updated
FROM footprints
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT 10
```

### GET /profile/:account_name

要求ログイン

``` sql
-- owner
SELECT * FROM users WHERE account_name = ?
-- => not found => 404

-- prof
SELECT * FROM profiles WHERE user_id = ? -- owner[:id]

-- entries
-- 1. permitted のとき
SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5 -- owner[:id]
-- 2. else
SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5 -- owner[:id]
-- => .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }

-- mark_footprint
```

erb :profile

### POST /profile/:account_name

### GET /diary/entries/:account_name

### GET /diary/entry/:entry_id

### POST /diary/entry

### POST /diary/comment/:entry_id

### GET /footprints

### GET /friends

### GET /friends/:account_name

### GET /initialize

初期化

```
DELETE FROM relations WHERE id > 500000
DELETE FROM footprints WHERE id > 500000
DELETE FROM entries WHERE id > 500000
DELETE FROM comments WHERE id > 1500000
```
