class Post < ApplicationRecord
  has_and_belongs_to_many :reasons
  has_many :feedbacks, :dependent => :destroy
  has_many :deletion_logs, :dependent => :destroy
  belongs_to :site
  belongs_to :stack_exchange_user
  belongs_to :smoke_detector
  has_many :flag_logs, :dependent => :destroy
  has_many :flags, dependent: :destroy

  scope :includes_for_post_row, -> { includes(:stack_exchange_user).includes(:reasons).includes(:feedbacks => [:user, :api_key]) }
  scope :without_feedback, -> { left_joins(:feedbacks).where( :feedbacks => { :post_id => nil }) }

  scope :autoflagged, -> {
    includes(:flag_logs).where(flag_logs: { is_auto: true }).where.not(flag_logs: { id: nil })
  }

  scope :not_autoflagged, -> {
    joins('LEFT OUTER JOIN flag_logs ON flag_logs.post_id = posts.id AND flag_logs.is_auto = 0').where(flag_logs: { id: nil })
  }

  after_create do
    ActionCable.server.broadcast "posts_realtime", { row: PostsController.render(locals: {post: Post.last}, partial: 'post').html_safe }
    ActionCable.server.broadcast "topbar", { review: Post.without_feedback.count }
  end

  after_create do
    post = self
    Thread.new do
      post.autoflag
    end
  end

  def autoflag
    return "Duplicate post" unless Post.where(:link => link).count == 1
    return "Flagging disabled" unless FlagSetting['flagging_enabled'] == '1'

    dry_run = FlagSetting['dry_run'] == '1'
    post = self

    begin
      conditions = post.site.flag_conditions.where(:flags_enabled => true)
      available_user_ids = {}
      conditions.each do |condition|
        if condition.validate!(post)
          available_user_ids[condition.user.id] = condition
        end
      end

      uids = post.site.user_site_settings.where(:user_id => available_user_ids.keys).map(&:user_id)
      users = User.where(:id => uids, :flags_enabled => true).where.not(:encrypted_api_token => nil)
      unless users.present?
        post.send_not_autoflagged
        return "No users eligible to flag"
      end

      post.fetch_revision_count
      unless post.revision_count == 1
        post.send_not_autoflagged
        return "More than one revision"
      end

      max_flags = [post.site.max_flags_per_post, (FlagSetting['max_flags'] || '3').to_i].min
      core_count = (max_flags / 2.0).ceil
      other_count = max_flags - core_count

      users.with_role(:core).shuffle.each do |user|
        if core_count <= 0
          break
        end
        core_count -= post.send_autoflag(user, dry_run, available_user_ids[user.id])
      end

      # Go through all non-core users first; then add core users at the end. See #146
      (users.without_role(:core).shuffle + users.with_role(:core).shuffle).each do |user|
        if other_count <= 0
          break
        end
        other_count -= post.send_autoflag(user, dry_run, available_user_ids[user.id])
      end
    rescue => e
      FlagLog.create(:success => false, :error_message => "#{e}: #{e.message} | #{e.backtrace.join("\n")}",
                     :is_dry_run => dry_run, :flag_condition => nil, :post => post,
                     :site_id => post.site_id)
    end

    post.send_not_autoflagged if post.flag_logs.where(:success => true).empty?
  end

  def send_autoflag(user, dry_run, condition)
    user_site_flag_count = user.flag_logs.where(:site => self.site, :success => true, :is_dry_run => false).where(:created_at => Date.today..Time.now).count
    return 0 if user_site_flag_count >= user.user_site_settings.includes(:sites).where(:sites => { :id => self.site.id } ).minimum(:max_flags)

    last_log = FlagLog.auto.where(:user => user).last
    if last_log.try(:backoff).present? && (last_log.created_at + last_log.backoff.seconds > Time.now)
      sleep((last_log.created_at + last_log.backoff.seconds) - Time.now)
    end

    success, message = user.spam_flag(self, dry_run)
    backoff = 0
    if success
      backoff = message
    end

    unless ["Flag options not present", "Spam flag option not present", "You do not have permission to flag this post", "No account on this site."].include? message
      flag_log = FlagLog.create(:success => success, :error_message => message,
                                :is_dry_run => dry_run, :flag_condition => condition,
                                :user => user, :post => self, :backoff => backoff,
                                :site_id => self.site_id)

      if success
        ActionCable.server.broadcast "api_flag_logs", { flag_log: JSON.parse(FlagLogController.render(locals: {flag_log: flag_log}, partial: 'flag_log.json')) }
        ActionCable.server.broadcast "flag_logs", { row: FlagLogController.render(locals: {log: flag_log}, partial: 'flag_log') }
      end
    end

    return success ? 1 : 0
  end

  def send_not_autoflagged
    ActionCable.server.broadcast "api_flag_logs", { not_flagged: { post_link: self.link, post: JSON.parse(PostsController.render(locals: {post: self}, partial: 'post.json')) } }
  end

  def update_feedback_cache
    self.is_tp = false
    self.is_fp = false

    feedbacks = self.feedbacks.to_a

    self.is_tp = true if feedbacks.index { |f| f.is_positive? }
    self.is_fp = true if feedbacks.index { |f| f.is_negative? }
    self.is_naa = true if feedbacks.index { |f| f.is_naa? }

    is_feedback_changed = self.is_tp_changed? || self.is_fp_changed? || self.is_naa_changed?

    save!

    if self.is_tp && self.is_fp
      SmokeDetector.send_message_to_charcoal "Conflicting feedback on [#{self.title}](//metasmoke.erwaysoftware.com/post/#{self.id})."
    end

    if self.is_fp_changed? && self.is_fp && self.flagged?
      SmokeDetector.send_message_to_charcoal "**fp on autoflagged post**: #{self.title}](//metasmoke.erwaysoftware.com/post/#{self.id})"
    end

    if is_feedback_changed
      ActionCable.server.broadcast "topbar", { review: Post.without_feedback.count }
    end

    return is_feedback_changed
  end

  def is_question?
    return self.link.include? "/questions/"
  end

  def is_answer?
    return self.link.include? "/a/"
  end

  def is_deleted?
    return self.deletion_logs.where(:is_deleted => true).any?
  end

  def stack_id
    return self.link.scan(/(\d*)$/).first.first.to_i
  end

  def flagged?
    if flag_logs.loaded?
      flag_logs.select { |f| f.success && f.is_auto }.present?
    else
      flag_logs.where(:success => true, :is_auto => true).present?
    end
  end

  def flaggers
    User.joins(:flag_logs).where(:flag_logs => {:success => true, :post_id => self.id, :is_auto => true})
  end

  def manual_flaggers
    User.joins(:flag_logs).where(:flag_logs => {:success => true, :post_id => self.id, :is_auto => false})
  end

  def fetch_revision_count(post=nil)
    post ||= self
    params = "key=#{AppConfig["stack_exchange"]["key"]}&site=#{post.site.site_domain}&filter=!mggE4ZSiE7"

    url = "https://api.stackexchange.com/2.2/posts/#{post.stack_id}/revisions?#{params}"
    revision_list = JSON.parse(Net::HTTP.get_response(URI.parse(url)).body)["items"]

    update(:revision_count => revision_list.count)
    revision_list.count
  end

  def get_revision_count
    if self.respond_to? :revision_count
      post = self
    else
      post = Post.find self.id
    end

    if post.revision_count.present?
      post.revision_count
    else
      fetch_revision_count(self.respond_to?(:revision_count) ? nil : post)
    end
  end
end
