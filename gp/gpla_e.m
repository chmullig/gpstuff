function [e, edata, eprior, f, L, a, La2, p] = gpla_e(w, gp, varargin)
%GPLA_E  Do Laplace approximation and return marginal log posterior estimate
%
%  Description
%    E = GPLA_E(W, GP, X, Y, OPTIONS) takes a GP structure GP
%    together with a matrix X of input vectors and a matrix Y of
%    target vectors, and finds the Laplace approximation for the
%    conditional posterior p(Y | X, th), where th is the
%    parameters. Returns the energy at th (see below). Each
%    row of X corresponds to one input vector and each row of Y
%    corresponds to one target vector.
%
%    [E, EDATA, EPRIOR] = GPLA_E(W, GP, X, Y, OPTIONS) returns also 
%    the data and prior components of the total energy.
%
%    The energy is minus log posterior cost function for th:
%      E = EDATA + EPRIOR 
%        = - log p(Y|X, th) - log p(th),
%      where th represents the parameters (lengthScale,
%      magnSigma2...), X is inputs and Y is observations.
%
%    OPTIONS is optional parameter-value pair
%      z - optional observed quantity in triplet (x_i,y_i,z_i)
%          Some likelihoods may use this. For example, in case of
%          Poisson likelihood we have z_i=E_i, that is, expected
%          value for ith case.
%
%  See also
%    GP_SET, GP_E, GPLA_G, GPLA_PRED
%
%  Description 2
%    Additional properties meant only for internal use.
%  
%    GP = GPLA_E('init', GP) takes a GP structure GP and
%    initializes required fields for the Laplace approximation.
% 
%    GP = GPLA_E('clearcache', GP) takes a GP structure GP and clears the
%    internal cache stored in the nested function workspace.
%
%    [e, edata, eprior, f, L, a, La2, p] = GPLA_E(w, gp, x, y, varargin)
%    returns many useful quantities produced by EP algorithm.
%
%    The Newton's method is implemented as described in Rasmussen
%    and Williams (2006).
%
%    The stabilized Newton's method is implemented as suggested by
%    Hannes Nickisch (personal communication).
  
% Copyright (c) 2007-2010 Jarno Vanhatalo
% Copyright (c) 2010 Aki Vehtari
% Copyright (c) 2010 Pasi Jyl�nki

% This software is distributed under the GNU General Public
% License (version 2 or later); please refer to the file
% License.txt, included with the software, for details.

  % parse inputs
  ip=inputParser;
  ip.FunctionName = 'GPLA_E';
  ip.addRequired('w', @(x) ...
                 isempty(x) || ...
                 (ischar(x) && strcmp(w, 'init')) || ...
                 isvector(x) && isreal(x) && all(isfinite(x)) ...
                 || all(isnan(x)));
  ip.addRequired('gp',@isstruct);
  ip.addOptional('x', @(x) isnumeric(x) && isreal(x) && all(isfinite(x(:))))
  ip.addOptional('y', @(x) isnumeric(x) && isreal(x) && all(isfinite(x(:))))
  ip.addParamValue('z', [], @(x) isnumeric(x) && isreal(x) && all(isfinite(x(:))))
  ip.parse(w, gp, varargin{:});
  x=ip.Results.x;
  y=ip.Results.y;
  z=ip.Results.z;
  
  if strcmp(w, 'init')
    % Initialize cache
    ch = [];
     
    % return function handle to the nested function ep_algorithm
    % this way each gp has its own peristent memory for EP
    gp.fh.e = @laplace_algorithm;
    e = gp;
    % remove clutter from the nested workspace
    clear w gp varargin ip x y z
  elseif strcmp(w, 'clearcache')
    % clear the cache
    gp.fh.e('clearcache');
  else
    % call laplace_algorithm using the function handle to the nested function
    % this way each gp has its own peristent memory for Laplace
    [e, edata, eprior, f, L, a, La2, p] = gp.fh.e(w, gp, x, y, z);
  end

  function [e, edata, eprior, f, L, a, La2, p] = laplace_algorithm(w, gp, x, y, z)
      
  if strcmp(w, 'clearcache')
      ch=[];
      return
  end
  % code for the Laplace algorithm
    
  % check whether saved values can be used
    if isempty(z)
      datahash=hash_sha512([x y]);
    else
      datahash=hash_sha512([x y z]);
    end
    if ~isempty(ch) && all(size(w)==size(ch.w)) && all(abs(w-ch.w)<1e-8) && ...
          isequal(datahash,ch.datahash)
      % The covariance function parameters or data haven't changed
      % so we can return the energy and the site parameters that are saved
      e = ch.e;
      edata = ch.edata;
      eprior = ch.eprior;
      f = ch.f;
      L = ch.L;
      La2 = ch.La2;
      a = ch.a;
      p = ch.p;
    else
      % The parameters or data have changed since
      % the last call for gpla_e. In this case we need to
      % re-evaluate the Laplace approximation
      gp=gp_unpak(gp, w);
      ncf = length(gp.cf);
      n = size(x,1);
      p = [];
      maxiter = gp.latent_opt.maxiter;

      % Initialize latent values
      % zero seems to be a robust choice (Jarno)
      % with mean functions, initialize to mean function values
      if ~isfield(gp,'meanf')
        f = zeros(size(y));
      else
        [H,b_m,B_m]=mean_prep(gp,x,[]);
        f = H'*b_m;
      end

      % =================================================
      % First Evaluate the data contribution to the error
      switch gp.type
        % ============================================================
        % FULL
        % ============================================================
        case 'FULL'
          K = gp_trcov(gp, x);
          if isfield(gp,'meanf')
              K=K+H'*B_m*H;  
          end

          % If K is sparse, permute all the inputs so that evaluations are more efficient
          if issparse(K)         % Check if compact support covariance is used
            p = analyze(K);
            y = y(p);
            K = K(p,p);
            if ~isempty(z)
              z = z(p,:);
            end
            [LD,notpositivedefinite] = ldlchol(K);
          else
            [LD,notpositivedefinite] = chol(K);
          end
          
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          
          switch gp.latent_opt.optim_method
            % --------------------------------------------------------------------------------
            % find the posterior mode of latent variables by fminunc
            case 'fminunc_large'
              if issparse(K)
                fhm = @(W, f, varargin) (ldlsolve(LD,f) + repmat(W,1,size(f,2)).*f);  % W*f; %
              else
                fhm = @(W, f, varargin) (LD\(LD'\f) + repmat(W,1,size(f,2)).*f);  % W*f; %
              end                            
              defopts=struct('GradObj','on','Hessian','on','HessMult', fhm,'TolX', 1e-12,'TolFun', 1e-12,'LargeScale', 'on','Display', 'off');
              if ~isfield(gp.latent_opt, 'fminunc_opt')
                opt = optimset(defopts);
              else
                opt = optimset(defopts,gp.latent_opt.fminunc_opt);
              end
              
              if issparse(K)
                fe = @(f, varargin) (0.5*f*(ldlsolve(LD,f')) - gp.lik.fh.ll(gp.lik, y, f', z));
                fg = @(f, varargin) (ldlsolve(LD,f') - gp.lik.fh.llg(gp.lik, y, f', 'latent', z))';
                fh = @(f, varargin) (-gp.lik.fh.llg2(gp.lik, y, f', 'latent', z)); %inv(K) + diag(g2(f', gp.lik)) ; %
              else
                fe = @(f, varargin) (0.5*f*(LD\(LD'\f')) - gp.lik.fh.ll(gp.lik, y, f', z));
                fg = @(f, varargin) (LD\(LD'\f') - gp.lik.fh.llg(gp.lik, y, f', 'latent', z))';
                fh = @(f, varargin) (-gp.lik.fh.llg2(gp.lik, y, f', 'latent', z)); %inv(K) + diag(g2(f', gp.lik)) ; %
              end
              
              mydeal = @(varargin)varargin{1:nargout};
              [f,fval,exitflag,output] = fminunc(@(ww) mydeal(fe(ww), fg(ww), fh(ww)), f', opt);
              f = f';

              if issparse(K)
                a = ldlsolve(LD,f);
              else
                a = LD\(LD'\f);
              end
              % --------------------------------------------------------------------------------
              % find the posterior mode of latent variables by Newton method
            case 'newton'
              tol = 1e-12;
              a = f;
              if isfield(gp,'meanf')
                a = a-H'*b_m;  
              end
              W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
              dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
              lp_new = gp.lik.fh.ll(gp.lik, y, f, z);
              lp_old = -Inf;
              
              iter=0;
              while abs(lp_new - lp_old) > tol && iter < maxiter
                iter = iter + 1;
                lp_old = lp_new; a_old = a; 
                sW = sqrt(W);    
                if issparse(K)
                  sW = sparse(1:n, 1:n, sW, n, n);
                  [L,notpositivedefinite] = ldlchol( speye(n)+sW*K*sW );
                else
                  [L,notpositivedefinite] = chol(eye(n)+sW*sW'.*K); % L'*L=B=eye(n)+sW*K*sW
                end
                if notpositivedefinite
                  [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
                  return
                end
                if ~isfield(gp,'meanf')                   
                  b = W.*f+dlp;
                else
                  b = W.*f+K\(H'*b_m)+dlp;
                end
                if issparse(K)
                  a = b - sW*ldlsolve(L,sW*(K*b));
                else
                  a = b - sW.*(L\(L'\(sW.*(K*b))));
                end
                f = K*a;
                lp = gp.lik.fh.ll(gp.lik, y, f, z);
                if ~isfield(gp,'meanf')
                  lp_new = -a'*f/2 + lp;
                else
                  lp_new = -(f-H'*b_m)'*(a-K\(H'*b_m))/2 + lp; %f^=f-H'*b_m,
                end
                i = 0;
                while i < 10 && lp_new < lp_old  || isnan(sum(f))
                  % reduce step size by half
                  a = (a_old+a)/2;                                  
                  f = K*a;
                  lp = gp.lik.fh.ll(gp.lik, y, f, z);
                  if ~isfield(gp,'meanf')
                      lp_new = -a'*f/2 + lp;
                  else
                      lp_new = -(f-H'*b_m)'*(a-K\(H'*b_m))/2 + lp;
                  end
                  i = i+1;
                end 
                W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
                dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
              end
              % --------------------------------------------------------------------------------
              % find the posterior mode of latent variables by stabilized Newton method.
              % This is implemented as suggested by Hannes Nickisch (personal communication)
            case 'stabilized-newton'
              % Gaussian initialization
              %   sigma=gp.lik.sigma;
              %   W = ones(n,1)./sigma.^2;
              %   sW = sqrt(W);
              %   %B = eye(n) + siV*siV'.*K;
              %   L=bsxfun(@times,bsxfun(@times,sW,K),sW');
              %   L(1:n+1:end)=L(1:n+1:end)+1;
              %   L = chol(L,'lower');
              %   a=sW.*(L'\(L\(sW.*y)));
              %   f = K*a;
              
              % initialize to observations
              %f=y;
             
              switch gp.lik.type
                % should be handled inside lik_*
                case 'Student-t'
                  nu=gp.lik.nu;
                  sigma2=gp.lik.sigma2;
                  Wmax=(nu+1)/nu/sigma2;
                case 'Negbinztr'
                  r=gp.lik.disper;
                  Wmax=1./((1+r)./(1*r));
                otherwise
                  Wmax=100;
              end
              Wlim=0;
              
              tol = 1e-10;
              W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
              dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
              lp = -(f'*(K\f))/2 +gp.lik.fh.ll(gp.lik, y, f, z);
              lp_old = -Inf;
              f_old = f+1;
              ge = Inf; %max(abs(a-dlp));
              
              iter=0;
              % begin Newton's iterations
              while (lp - lp_old > tol || max(abs(f-f_old)) > tol) && iter < maxiter
                iter=iter+1;
                
                W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
                dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
                
                W(W<Wlim)=Wlim;
                sW = sqrt(W);
                if issparse(K)
                  sW = sparse(1:n, 1:n, sW, n, n);
                  [L, notpositivedefinite] = ldlchol( speye(n)+sW*K*sW );
                else
                  %L = chol(eye(n)+sW*sW'.*K); % L'*L=B=eye(n)+sW*K*sW
                  L=bsxfun(@times,bsxfun(@times,sW,K),sW');
                  L(1:n+1:end)=L(1:n+1:end)+1;
                  [L, notpositivedefinite] = chol(L);
                end
                if notpositivedefinite
                  [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
                  return
                end
                %L = chol(eye(n)+sW*sW'.*K); % L'*L=B=eye(n)+sW*K*sW
                b = W.*f+dlp;
                if issparse(K)
                  a = b - sW*ldlsolve(L,sW*(K*b));
                else
                  a = b - sW.*(L\(L'\(sW.*(K*b))));
                end
                
                f_new = K*a;
                lp_new = -(a'*f_new)/2 + gp.lik.fh.ll(gp.lik, y, f_new, z);
                ge_new=max(abs(a-dlp));
                
                d=lp_new-lp;
                if (d<-1e-6 || (abs(d)<1e-6 && ge_new>ge) )  && Wlim<Wmax*0.5
                  %fprintf('%3d, p(f)=%.12f, max|a-g|=%.12f, %.3f \n',i1,lp,ge,Wlim)
                  Wlim=Wlim+Wmax*0.05; %Wmax*0.01
                else
                  Wlim=0;
                  
                  ge=ge_new;
                  lp_old = lp;
                  lp = lp_new;
                  f_old = f;
                  f = f_new;
                  %fprintf('%3d, p(f)=%.12f, max|a-g|=%.12f, %.3f \n',i1,lp,ge,Wlim)
                  
                end
                
                if Wlim>Wmax
                  %fprintf('\n%3d, p(f)=%.12f, max|a-g|=%.12f, %.3f \n',i1,lp,ge,Wlim)
                  break
                end
              end

              % --------------------------------------------------------------------------------
              % find the posterior mode of latent variables with likelihood specific algorithm
              % For example, with Student-t likelihood this mean EM-algorithm which is coded in the
              % lik_t file.
            case 'lik_specific'
              [f, a] = gp.lik.fh.optimizef(gp, y, K);
            otherwise 
              error('gpla_e: Unknown optimization method ! ')
          end
          
          % evaluate the approximate log marginal likelihood
          W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
          if ~isfield(gp,'meanf')
              logZ = 0.5 *f'*a - gp.lik.fh.ll(gp.lik, y, f, z);
          else
              logZ = 0.5 *((f-H'*b_m)'*(a-K\(H'*b_m))) - gp.lik.fh.ll(gp.lik, y, f, z);
          end
          if min(W) >= 0             % This is the usual case where likelihood is log concave
                                     % for example, Poisson and probit
            if issparse(K)
              W = sparse(1:n,1:n, -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z), n,n);
              sqrtW = sqrt(W);
              B = sparse(1:n,1:n,1,n,n) + sqrtW*K*sqrtW;
              [L, notpositivedefinite] = ldlchol(B);

              % Note that here we use LDL cholesky
              edata = logZ + 0.5.*sum(log(diag(L))); % 0.5*log(det(eye(size(K)) + K*W)) ; %                        
            else
              sW = sqrt(W);
              B = eye(size(K)) + sW*sW'.*K;
              [L, notpositivedefinite] = chol(B, 'lower');
              edata = logZ + sum(log(diag(L))); % 0.5*log(det(eye(size(K)) + K*W)) ; %
            end
            if notpositivedefinite
              [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
              return
            end
          else                        % We may end up here if the likelihood is not log concace
                                      % For example Student-t likelihood. 
          [W2,I] = sort(W, 1, 'descend');

          if issparse(K)
            error(['gpla_e: Unfortunately the compact support covariance (CS) functions do not work if'...
                   'the second gradient of negative likelihood is negative. This happens for example  '...
                   'with Student-t likelihood. Please use non-CS functions instead (e.g. gpcf_sexp)   ']);
          end

          [L, notpositivedefinite] = chol(K);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          L1 = L;
          for jj=1:size(K,1)
            i = I(jj);
            ll = sum(L(:,i).^2);
            l = L'*L(:,i);
            upfact = W(i)./(1 + W(i).*ll);
            
            % Check that Cholesky factorization will remain positive definite
            if 1./ll + W(i) < 0 %1 + W(i).*ll <= 0 | abs(upfact) > abs(1./ll) %upfact > 1./ll
              warning('gpla_e: 1./Sigma(i,i) + W(i) < 0')
              
              ind = 1:i-1;
              if isempty(z)
                mu = K(i,ind)*gp.lik.fh.llg(gp.lik, y(I(ind)), f(I(ind)), 'latent', z);
              else
                mu = K(i,ind)*gp.lik.fh.llg(gp.lik, y(I(ind)), f(I(ind)), 'latent', z(I(ind)));
              end
              upfact = gp.lik.fh.upfact(gp, y(I(i)), mu, ll);
            end
            if upfact > 0
              L = cholupdate(L, l.*sqrt(upfact), '-');
            else
              L = cholupdate(L, l.*sqrt(-upfact));
            end
          end
          edata = logZ + sum(log(diag(L1))) - sum(log(diag(L)));
          end
          
          La2 = W;

          % ============================================================
          % FIC
          % ============================================================
        case 'FIC'
          u = gp.X_u;
          m = length(u);

          % First evaluate needed covariance matrices
          % v defines that parameter is a vector
          [Kv_ff, Cv_ff] = gp_trvar(gp, x);  % f x 1  vector
          K_fu = gp_cov(gp, x, u);         % f x u                
          K_uu = gp_trcov(gp, u);    % u x u, noiseles covariance K_uu
          [Luu, notpositivedefinite] = chol(K_uu, 'lower');
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          % Evaluate the Lambda (La)
          % Q_ff = K_fu*inv(K_uu)*K_fu'
          % Here we need only the diag(Q_ff), which is evaluated below
          B=Luu\(K_fu');       % u x f
          Qv_ff=sum(B.^2)';
          Lav = Cv_ff-Qv_ff;   % f x 1, Vector of diagonal elements
          iLaKfu = repmat(Lav,1,m).\K_fu;  % f x u
          A = K_uu+K_fu'*iLaKfu;  A = (A+A')./2;     % Ensure symmetry
          [A, notpositivedefinite] = chol(A);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          L = iLaKfu/A;
          
          switch gp.latent_opt.optim_method
            % --------------------------------------------------------------------------------
            % find the posterior mode of latent variables by fminunc large scale method
            case 'fminunc_large'
              fhm = @(W, f, varargin) (f./repmat(Lav,1,size(f,2)) - L*(L'*f)  + repmat(W,1,size(f,2)).*f);  % hessian*f; %
              defopts=struct('GradObj','on','Hessian','on','HessMult', fhm,'TolX', 1e-8,'TolFun', 1e-8,'LargeScale', 'on','Display', 'off');
              if ~isfield(gp.latent_opt, 'fminunc_opt')
                opt = optimset(defopts);
              else
                opt = optimset(defopts,gp.latent_opt.fminunc_opt);
              end

              fe = @(f, varargin) (0.5*f*(f'./repmat(Lav,1,size(f',2)) - L*(L'*f')) - gp.lik.fh.ll(gp.lik, y, f', z));
              fg = @(f, varargin) (f'./repmat(Lav,1,size(f',2)) - L*(L'*f') - gp.lik.fh.llg(gp.lik, y, f', 'latent', z))';
              fh = @(f, varargin) (-gp.lik.fh.llg2(gp.lik, y, f', 'latent', z));
              mydeal = @(varargin)varargin{1:nargout};
              [f,fval,exitflag,output] = fminunc(@(ww) mydeal(fe(ww), fg(ww), fh(ww)), f', opt);
              f = f';

              a = f./Lav - L*L'*f;
              
              % --------------------------------------------------------------------------------
              % find the posterior mode of latent variables by Newton method
            case 'newton'
              tol = 1e-12;
              a = f;
              W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
              dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
              lp_new = gp.lik.fh.ll(gp.lik, y, f, z);
              lp_old = -Inf;
              
              iter = 0;
              while lp_new - lp_old > tol && iter < maxiter
                iter = iter + 1;
                lp_old = lp_new; a_old = a; 
                sW = sqrt(W);
                
                Lah = 1 + sW.*Lav.*sW;
                sWKfu = repmat(sW,1,m).*K_fu;
                A = K_uu + sWKfu'*(repmat(Lah,1,m).\sWKfu);   A = (A+A')./2;
                Lb = (repmat(Lah,1,m).\sWKfu)/chol(A);
                b = W.*f+dlp;
                b2 = sW.*(Lav.*b + B'*(B*b));
                a = b - sW.*(b2./Lah - Lb*(Lb'*b2));
                
                f = Lav.*a + B'*(B*a);
                W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
                dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
                lp = gp.lik.fh.ll(gp.lik, y, f, z);
                lp_new = -a'*f/2 + lp;
                i = 0;
                while i < 10 && lp_new < lp_old      || isnan(sum(f))
                  % reduce step size by half
                  a = (a_old+a)/2;                                  
                  f = Lav.*a + B'*(B*a);
                  W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
                  lp = gp.lik.fh.ll(gp.lik, y, f, z);
                  lp_new = -a'*f/2 + lp;
                  i = i+1;
                end 
              end
              % --------------------------------------------------------------------------------
              % find the posterior mode of latent variables with likelihood specific algorithm
              % For example, with Student-t likelihood this mean EM-algorithm which is coded in the
              % lik_t file.
            case 'lik_specific'
              [f, a] = gp.lik.fh.optimizef(gp, y, K_uu, Lav, K_fu);
            otherwise 
              error('gpla_e: Unknown optimization method ! ')
          end
          
          W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
          logZ = 0.5*f'*a - gp.lik.fh.ll(gp.lik, y, f, z);
          
          if W >= 0
            sqrtW = sqrt(W);
            
            Lah = 1 + sqrtW.*Lav.*sqrtW;
            sWKfu = repmat(sqrtW,1,m).*K_fu;
            A = K_uu + sWKfu'*(repmat(Lah,1,m).\sWKfu);   A = (A+A')./2;
            [A, notpositivedefinite] = chol(A);
            if notpositivedefinite
              [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
              return
            end
            edata = sum(log(Lah)) - 2*sum(log(diag(Luu))) + 2*sum(log(diag(A)));
            edata = logZ + 0.5*edata;
          else
            % This is with full matrices. Needs to be rewritten.
            K = diag(Lav) + B'*B;
  % $$$                         [W,I] = sort(W, 1, 'descend');
  % $$$                         K = K(I,I);
            [W2,I] = sort(W, 1, 'descend');
            
            [L, notpositivedefinite] = chol(K);
            if notpositivedefinite
              [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
              return
            end
            L1 = L;
            for jj=1:size(K,1)
              i = I(jj);
              ll = sum(L(:,i).^2);
              l = L'*L(:,i);
              upfact = W(i)./(1 + W(i).*ll);
              
              % Check that Cholesky factorization will remain positive definite
              if 1 + W(i).*ll <= 0 | upfact > 1./ll
                warning('gpla_e: 1 + W(i).*ll < 0')
                
                ind = 1:i-1;
                if isempty(z)
                  mu = K(i,ind)*gp.lik.fh.llg(gp.lik, y(I(ind)), f(I(ind)), 'latent', z);
                else
                  mu = K(i,ind)*gp.lik.fh.llg(gp.lik, y(I(ind)), f(I(ind)), 'latent', z(I(ind)));
                end
                upfact = gp.lik.fh.upfact(gp, y(I(i)), mu, ll);
                
  % $$$                                 W2 = -1./(ll+1e-3);
  % $$$                                 upfact = W2./(1 + W2.*ll);
              end
              if upfact > 0
                L = cholupdate(L, l.*sqrt(upfact), '-');
              else
                L = cholupdate(L, l.*sqrt(-upfact));
              end
            end
            edata = logZ + sum(log(diag(L1))) - sum(log(diag(L)));  % sum(log(diag(chol(K)))) + sum(log(diag(chol((inv(K) + W)))));
          end
          
          
          La2 = Lav;

          % ============================================================
          % PIC
          % ============================================================
        case {'PIC' 'PIC_BLOCK'}
          ind = gp.tr_index;
          u = gp.X_u;
          m = length(u);

          % First evaluate needed covariance matrices
          % v defines that parameter is a vector
          K_fu = gp_cov(gp, x, u);         % f x u
          K_uu = gp_trcov(gp, u);    % u x u, noiseles covariance K_uu
          K_uu = (K_uu+K_uu')./2;     % ensure the symmetry of K_uu
          [Luu, notpositivedefinite] = chol(K_uu, 'lower');
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          % Evaluate the Lambda (La)
          % Q_ff = K_fu*inv(K_uu)*K_fu'
          % Here we need only the diag(Q_ff), which is evaluated below
          B=Luu\(K_fu');       % u x f

          % First some helper parameters
          iLaKfu = zeros(size(K_fu));  % f x u
          for i=1:length(ind)
            Qbl_ff = B(:,ind{i})'*B(:,ind{i});
            [Kbl_ff, Cbl_ff] = gp_trcov(gp, x(ind{i},:));
            Labl{i} = Cbl_ff - Qbl_ff;
            [LLabl{i}, notpositivedefinite] = chol(Labl{i});
            if notpositivedefinite
              [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
              return
            end
            iLaKfu(ind{i},:) = LLabl{i}\(LLabl{i}'\K_fu(ind{i},:));
          end
          A = K_uu+K_fu'*iLaKfu;
          A = (A+A')./2;     % Ensure symmetry
          [A, notpositivedefinite] = chol(A);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          L = iLaKfu/A;
          % Begin optimization
          switch gp.latent_opt.optim_method
            % --------------------------------------------------------------------------------
            % find the posterior mode of latent variables by fminunc large scale method
            case 'fminunc_large'
              fhm = @(W, f, varargin) (iKf(f)  + repmat(W,1,size(f,2)).*f);
              defopts=struct('GradObj','on','Hessian','on','HessMult', fhm,'TolX', 1e-8,'TolFun', 1e-8,'LargeScale', 'on','Display', 'off');
              if ~isfield(gp.latent_opt, 'fminunc_opt')
                opt = optimset(defopts);
              else
                opt = optimset(defopts,gp.latent_opt.fminunc_opt);
              end

              [f,fval,exitflag,output] = fminunc(@(ww) egh(ww), f', opt);
              f = f';
              
              a = iKf(f);
              
              % find the mode by Newton's method
              % --------------------------------------------------------------------------------
            case 'newton'
              tol = 1e-12;
              a = f;
              W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
              dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
              lp_new = gp.lik.fh.ll(gp.lik, y, f, z);
              lp_old = -Inf;
              
              iter = 0;
              while lp_new - lp_old > tol && iter < maxiter
                iter = iter + 1;
                lp_old = lp_new; a_old = a;
                sW = sqrt(W);

                V = repmat(sW,1,m).*K_fu;
                for i=1:length(ind)
                  Lah{i} = eye(size(Labl{i})) + diag(sW(ind{i}))*Labl{i}*diag(sW(ind{i}));
                  [LLah{i}, notpositivedefinite] = chol(Lah{i});
                  if notpositivedefinite
                    [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
                    return
                  end
                  V2(ind{i},:) = LLah{i}\(LLah{i}'\V(ind{i},:));
                end                        
                
                A = K_uu + V'*V2;   A = (A+A')./2;
                [A, notpositivedefinite] = chol(A);
                if notpositivedefinite
                  [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
                  return
                end
                Lb = V2/A;
                b = W.*f+dlp;
                b2 = B'*(B*b);
                bt = zeros(size(b2));
                for i=1:length(ind)
                  b2(ind{i}) = sW(ind{i}).*(Labl{i}*b(ind{i}) + b2(ind{i})); 
                  bt(ind{i}) = LLah{i}\(LLah{i}'\b2(ind{i}));
                end
                a = b - sW.*(bt - Lb*(Lb'*b2));

                f = B'*(B*a);
                for i=1:length(ind)
                  f(ind{i}) = Labl{i}*a(ind{i}) + f(ind{i}) ;
                end
                W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
                dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
                lp = gp.lik.fh.ll(gp.lik, y, f, z);
                lp_new = -a'*f/2 + lp;
                i = 0;
                while i < 10 && lp_new < lp_old || isnan(sum(f))
                  % reduce step size by half
                  a = (a_old+a)/2;                                  
                  f = B'*(B*a);
                  for i=1:length(ind)
                    f(ind{i}) = Labl{i}*a(ind{i}) + f(ind{i}) ;
                  end
                  W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
                  lp = gp.lik.fh.ll(gp.lik, y, f, z);
                  lp_new = -a'*f/2 + lp;
                  i = i+1;
                end 
              end
            otherwise 
              error('gpla_e: Unknown optimization method ! ')    
          end
          
          W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
          sqrtW = sqrt(W);
          
          logZ = 0.5*f'*a - gp.lik.fh.ll(gp.lik, y, f, z);
          
          WKfu = repmat(sqrtW,1,m).*K_fu;
          edata = 0;
          for i=1:length(ind)
            Lahat = eye(size(Labl{i})) + diag(sqrtW(ind{i}))*Labl{i}*diag(sqrtW(ind{i}));
            [LLahat, notpositivedefinite] = chol(Lahat);
            if notpositivedefinite
              [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
              return
            end
            iLahatWKfu(ind{i},:) = LLahat\(LLahat'\WKfu(ind{i},:));
            edata = edata + 2.*sum(log(diag(LLahat)));
          end
          A = K_uu + WKfu'*iLahatWKfu;   A = (A+A')./2;
          [A, notpositivedefinite] = chol(A);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          edata =  edata - 2*sum(log(diag(Luu))) + 2*sum(log(diag(A)));
          edata = logZ + 0.5*edata;

          La2 = Labl;              
          
          % ============================================================
          % CS+FIC
          % ============================================================
        case 'CS+FIC'
          u = gp.X_u;
          m = length(u);
          cf_orig = gp.cf;

          cf1 = {};
          cf2 = {};
          j = 1;
          k = 1;
          for i = 1:ncf
            if ~isfield(gp.cf{i},'cs')
              cf1{j} = gp.cf{i};
              j = j + 1;
            else
              cf2{k} = gp.cf{i};
              k = k + 1;
            end
          end
          gp.cf = cf1;

          % First evaluate needed covariance matrices
          % v defines that parameter is a vector
          [Kv_ff, Cv_ff] = gp_trvar(gp, x);  % f x 1  vector
          K_fu = gp_cov(gp, x, u);         % f x u
          K_uu = gp_trcov(gp, u);    % u x u, noiseles covariance K_uu
          K_uu = (K_uu+K_uu')./2;     % ensure the symmetry of K_uu
          [Luu, notpositivedefinite] = chol(K_uu, 'lower');
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end

          % Evaluate the Lambda (La)
          % Q_ff = K_fu*inv(K_uu)*K_fu'
          B=Luu\(K_fu');       % u x f
          Qv_ff=sum(B.^2)';
          Lav = Cv_ff-Qv_ff;   % f x 1, Vector of diagonal elements
          
          gp.cf = cf2;
          K_cs = gp_trcov(gp,x);
          La = sparse(1:n,1:n,Lav,n,n) + K_cs;
          gp.cf = cf_orig;
          
          % Find fill reducing permutation and permute all the
          % matrices
          p = analyze(La);
          r(p) = 1:n;
          if ~isempty(z)
            z = z(p,:);
          end
          f = f(p);
          y = y(p);
          La = La(p,p);
          K_fu = K_fu(p,:);
          B = B(:,p);
          [VD, notpositivedefinite] = ldlchol(La);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          
          iLaKfu = ldlsolve(VD,K_fu);
          %iLaKfu = La\K_fu;

          A = K_uu+K_fu'*iLaKfu;  A = (A+A')./2;     % Ensure symmetry
          [A, notpositivedefinite] = chol(A);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          L = iLaKfu/A;
          % Begin optimization
          switch gp.latent_opt.optim_method

            % --------------------------------------------------------------------------------
            % find the posterior mode of latent variables by fminunc large scale method
            case 'fminunc_large'
              fhm = @(W, f, varargin) (ldlsolve(VD,f) - L*(L'*f)  + repmat(W,1,size(f,2)).*f);  % Hessian*f; % La\f
              defopts=struct('GradObj','on','Hessian','on','HessMult', fhm,'TolX', 1e-8,'TolFun', 1e-8,'LargeScale', 'on','Display', 'off');
              if ~isfield(gp.latent_opt, 'fminunc_opt')
                opt = optimset(defopts);
              else
                opt = optimset(defopts,gp.latent_opt.fminunc_opt);
              end
              
              [f,fval,exitflag,output] = fminunc(@(ww) egh(ww), f', opt);
              f = f';
              
              a = ldlsolve(VD,f) - L*L'*f;
              
              % --------------------------------------------------------------------------------
              % find the posterior mode of latent variables by Newton method
            case 'newton'
              tol = 1e-8;
              a = f;
              W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
              dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
              lp_new = gp.lik.fh.ll(gp.lik, y, f, z);
              lp_old = -Inf;
              I = sparse(1:n,1:n,1,n,n);
              
              iter = 0;
              while lp_new - lp_old > tol && iter < maxiter
                iter = iter + 1;
                lp_old = lp_new; a_old = a; 
                sW = sqrt(W);
                sqrtW = sparse(1:n,1:n,sW,n,n);
                
                Lah = I + sqrtW*La*sqrtW; 
                [VDh, notpositivedefinite] = ldlchol(Lah);
                if notpositivedefinite
                  [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
                  return
                end
                V = repmat(sW,1,m).*K_fu;
                Vt = ldlsolve(VDh,V);
                A = K_uu + V'*Vt;   A = (A+A')./2;
                [A, notpositivedefinite] = chol(A);
                if notpositivedefinite
                  [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
                  return
                end
                Lb = Vt/A;
                b = W.*f+dlp;
                b2 = sW.*(La*b + B'*(B*b));
                a = b - sW.*(ldlsolve(VDh,b2) - Lb*(Lb'*b2) );

                f = La*a + B'*(B*a);
                W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
                dlp = gp.lik.fh.llg(gp.lik, y, f, 'latent', z);
                lp = gp.lik.fh.ll(gp.lik, y, f, z);
                lp_new = -a'*f/2 + lp;
                i = 0;
                while i < 10 && lp_new < lp_old
                  a = (a_old+a)/2;
                  f = La*a + B'*(B*a);
                  W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
                  lp = gp.lik.fh.ll(gp.lik, y, f, z);
                  lp_new = -a'*f/2 + lp;
                  i = i+1;
                end
              end
            otherwise 
              error('gpla_e: Unknown optimization method ! ')
          end
          
          
          W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
          sqrtW = sqrt(W);
          
          logZ = 0.5*f'*a - gp.lik.fh.ll(gp.lik, y, f, z);
          
          WKfu = repmat(sqrtW,1,m).*K_fu;
          sqrtW = sparse(1:n,1:n,sqrtW,n,n);
          Lahat = sparse(1:n,1:n,1,n,n) + sqrtW*La*sqrtW;
          [LDh, notpositivedefinite] = ldlchol(Lahat);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          A = K_uu + WKfu'*ldlsolve(LDh,WKfu);   A = (A+A')./2;
          [A, notpositivedefinite] = chol(A);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          edata = sum(log(diag(LDh))) - 2*sum(log(diag(Luu))) + 2*sum(log(diag(A)));
          edata = logZ + 0.5*edata;
          
          La2 = La;
          
          % Reorder all the returned and stored values
          a = a(r);
          L = L(r,:);
          La2 = La2(r,r);
          y = y(r);
          f = f(r);
          W = W(r);
          if ~isempty(z)
            z = z(r,:);
          end
          
          % ============================================================
          % SSGP
          % ============================================================
        case 'SSGP'        % Predictions with sparse spectral sampling approximation for GP
                           % The approximation is proposed by M. Lazaro-Gredilla, J. Quinonero-Candela and A. Figueiras-Vidal
                           % in Microsoft Research technical report MSR-TR-2007-152 (November 2007)
                           % NOTE! This does not work at the moment.
          
          % First evaluate needed covariance matrices
          % v defines that parameter is a vector
          [Phi, S] = gp_trcov(gp, x);        % n x m matrix and nxn sparse matrix
          Sv = diag(S);
          
          m = size(Phi,2);
          
          A = eye(m,m) + Phi'*(S\Phi);
          [A, notpositivedefinite] = chol(A, 'lower');
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          L = (S\Phi)/A';
          
          switch gp.latent_opt.optim_method
            % find the mode by fminunc large scale method
            case 'fminunc_large'
              fhm = @(W, f, varargin) (f./repmat(Sv,1,size(f,2)) - L*(L'*f)  + repmat(W,1,size(f,2)).*f);  % Hessian*f; %
              defopts=struct('GradObj','on','Hessian','on','HessMult', fhm,'TolX', 1e-8,'TolFun', 1e-8,'LargeScale', 'on','Display', 'off');
              if ~isfield(gp.latent_opt, 'fminunc_opt')
                opt=optimset(defopts);
              else
                opt = optimset(defopts,gp.latent_opt.fminunc_opt);
              end

              fe = @(f, varargin) (0.5*f*(f'./repmat(Sv,1,size(f',2)) - L*(L'*f')) - gp.lik.fh.ll(gp.lik, y, f', z));
              fg = @(f, varargin) (f'./repmat(Sv,1,size(f',2)) - L*(L'*f') - gp.lik.fh.llg(gp.lik, y, f', 'latent', z))';
              fh = @(f, varargin) (-gp.lik.fh.llg2(gp.lik, y, f', 'latent', z));
              mydeal = @(varargin)varargin{1:nargout};
              [f,fval,exitflag,output] = fminunc(@(ww) mydeal(fe(ww), fg(ww), fh(ww)), f', opt);
              f = f';

              W = -gp.lik.fh.llg2(gp.lik, y, f, 'latent', z);
              sqrtW = sqrt(W);

              b = L'*f;
              logZ = 0.5*(f'*(f./Sv) - b'*b) - gp.lik.fh.ll(gp.lik, y, f, z);
            case 'Newton'
              error('The Newton''s method is not implemented for FIC!\n')
          end
          WPhi = repmat(sqrtW,1,m).*Phi;
          A = eye(m,m) + WPhi'./repmat((1+Sv.*W)',m,1)*WPhi;   A = (A+A')./2;
          [A, notpositivedefinite] = chol(A);
          if notpositivedefinite
            [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite();
            return
          end
          edata = sum(log(1+Sv.*W)) + 2*sum(log(diag(A)));
          edata = logZ + 0.5*edata;

          La2 = Sv;

        otherwise
          error('Unknown type of Gaussian process!')
      end

      % ======================================================================
      % Evaluate the prior contribution to the error from covariance functions
      % ======================================================================
      eprior = 0;
      for i=1:ncf
        gpcf = gp.cf{i};
        eprior = eprior - gpcf.fh.lp(gpcf);
      end

      % ======================================================================
      % Evaluate the prior contribution to the error from likelihood function
      % ======================================================================
      if isfield(gp, 'lik') && isfield(gp.lik, 'p')
        lik = gp.lik;
        eprior = eprior - lik.fh.lp(lik);
      end

      e = edata + eprior;
    
      % store values to the cache
      ch.w = w;
      ch.e = e;
      ch.edata = edata;
      ch.eprior = eprior;
      ch.f = f;
      ch.L = L;
%       ch.W = W;
      ch.n = size(x,1);
      ch.La2 = La2;
      ch.a = a;
      ch.p=p;
      ch.datahash=datahash;
    end
    
    assert(isreal(edata))
    assert(isreal(eprior))

%
% ==============================================================
% Begin of the nested functions
% ==============================================================
%        
function [e, g, h] = egh(f, varargin)
  ikf = iKf(f');
  e = 0.5*f*ikf - gp.lik.fh.ll(gp.lik, y, f', z);
  g = (ikf - gp.lik.fh.llg(gp.lik, y, f', 'latent', z))';
  h = -gp.lik.fh.llg2(gp.lik, y, f', 'latent', z);
end
function ikf = iKf(f, varargin)
  
  switch gp.type
    case {'PIC' 'PIC_BLOCK'}
      iLaf = zeros(size(f));
      for i=1:length(ind)
        iLaf(ind2depo{i},:) = LLabl{i}\(LLabl{i}'\f(ind{i},:));
      end
      ikf = iLaf - L*(L'*f);
    case 'CS+FIC'
      ikf = ldlsolve(VD,f) - L*(L'*f);
  end
end
end
function [edata,e,eprior,f,L,a,La2,p,ch] = set_output_for_notpositivedefinite()
  % Instead of stopping to chol error, return NaN
  edata=NaN;
  e=NaN;
  eprior=NaN;
  f=NaN;
  L=NaN;
  a=NaN;
  La2=NaN;
  p=NaN;
  datahash = NaN;
  w = NaN;
  ch.e = e;
  ch.edata = edata;
  ch.eprior = eprior;
  ch.f = f;
  ch.L = L;
  ch.La2 = La2;
  ch.a = a;
  ch.p=p;
  ch.datahash=datahash;
  ch.w = NaN;
end

end
